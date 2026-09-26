import Foundation

/// Turns audio into a transcript and notes, one meeting at a time:
/// diarize (Swift, CoreML) || transcribe (engine, MLX) -> align (engine) -> notes (engine, streamed).
@MainActor
final class MeetingPipeline: ObservableObject {
    /// Notes text as it streams from the LLM, keyed by meeting.
    @Published private(set) var liveNotes: [UUID: String] = [:]
    @Published private(set) var activeMeeting: UUID?

    let store: MeetingStore
    let engine: EngineManager
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var current: Task<Void, Never>?

    init(store: MeetingStore, engine: EngineManager) {
        self.store = store
        self.engine = engine
    }

    /// Requeue meetings that were waiting when the app last quit.
    func resumePending() {
        for m in store.meetings.reversed() where m.status == .queued { enqueue(m.id) }
    }

    func enqueue(_ id: UUID) {
        guard !queue.contains(id), activeMeeting != id else { return }
        queue.append(id)
        store.update(id) { $0.status = .queued; $0.error = nil; $0.progress = nil; $0.stageDetail = nil }
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            activeMeeting = id
            let task = Task { await self.process(id) }
            current = task
            await task.value
            current = nil
            activeMeeting = nil
        }
        worker = nil
    }

    /// Runs one meeting to completion (used directly by minutes-cli).
    func processNow(_ id: UUID) async {
        await process(id)
    }

    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        if activeMeeting == id { current?.cancel() }
        store.update(id) {
            if $0.status.isWorking { $0.status = .failed; $0.error = "Cancelled"; $0.progress = nil }
        }
    }

    // MARK: - Inputs

    /// Copies/converts a file into a new meeting and queues it.
    @discardableResult
    func importFile(_ url: URL) async -> UUID? {
        let name = url.lastPathComponent
        guard let meeting = try? store.create(title: url.deletingPathExtension().lastPathComponent, source: name,
                                              status: .importing) else { return nil }
        let id = meeting.id
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let duration = try await AudioImporter.convert(url, to: store.audioURL(id)) { p in
                Task { @MainActor in self.store.update(id) { $0.progress = p } }
            }
            store.update(id) { $0.duration = duration; $0.progress = nil }
            enqueue(id)
        } catch {
            store.update(id) { $0.status = .failed; $0.error = error.localizedDescription; $0.progress = nil }
        }
        return id
    }

    func finishRecording(_ id: UUID, result: RecordingResult) {
        store.update(id) {
            $0.duration = result.duration
            $0.warnings += result.warnings
        }
        enqueue(id)
    }

    /// Re-runs only the notes step, e.g. after renaming speakers.
    func regenerateNotes(_ id: UUID) {
        guard activeMeeting != id else { return }
        Task {
            do {
                guard let transcript = store.transcript(id) else { return }
                try await writeNotes(id, turns: transcript.turns)
                store.update(id) { $0.status = .done; $0.progress = nil; $0.stageDetail = nil }
            } catch {
                store.update(id) { $0.status = .failed; $0.error = error.localizedDescription }
            }
            liveNotes[id] = nil
        }
    }

    // MARK: - Processing

    private func process(_ id: UUID) async {
        guard store.meeting(id) != nil else { return }
        let audio = store.audioURL(id)
        do {
            guard FileManager.default.fileExists(atPath: audio.path) else {
                throw MinutesError.audio("this meeting has no audio file")
            }
            setStage(id, .transcribing, "Starting engine")
            let client = try await engine.ensureReady()
            let settings = engine.diarizationSettings
            store.update(id) { $0.profile = self.engine.activeProfile?.name }

            setStage(id, .transcribing, "Transcribing and identifying speakers")
            async let diarized: Result<[SpeakerSegment], Error> = Self.diarize(audio, settings: settings)
            let asr = try await client.transcribe(audioURL: audio) { [weak self] event in
                guard event.type == "progress", let v = event.value else { return }
                Task { @MainActor in self?.store.update(id) { $0.progress = v } }
            }
            var segments: [SpeakerSegment] = []
            switch await diarized {
            case .success(let s): segments = s
            case .failure(let error):
                store.update(id) { $0.warnings.append("Speaker identification failed, showing one speaker: \(error.localizedDescription)") }
            }
            try Task.checkCancellation()

            setStage(id, .aligning, "Matching words to speakers")
            let turns = try await client.align(words: asr.words, segments: segments)
            try store.saveTranscript(
                Transcript(turns: turns, segments: segments, asrModel: asr.model, diarization: settings), for: id)
            try Task.checkCancellation()

            try await writeNotes(id, turns: turns)
            store.update(id) { $0.status = .done; $0.progress = nil; $0.stageDetail = nil; $0.error = nil }
        } catch is CancellationError {
            store.update(id) { $0.status = .failed; $0.error = "Cancelled"; $0.progress = nil }
        } catch {
            store.update(id) { $0.status = .failed; $0.error = error.localizedDescription; $0.progress = nil }
        }
        liveNotes[id] = nil
    }

    private func writeNotes(_ id: UUID, turns: [Turn]) async throws {
        setStage(id, .summarizing, "Writing notes")
        let client = try await engine.ensureReady()
        let names = store.meeting(id)?.speakerNamesByID ?? [:]
        liveNotes[id] = ""
        let result = try await client.notes(turns: turns, speakerNames: names) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event.type {
                case "token":
                    self.liveNotes[id, default: ""] += event.text ?? ""
                case "stage":
                    let detail: String
                    switch event.stage {
                    case "map": detail = "Reading part \(event.index ?? 0) of \(event.total ?? 0)"
                    case "merge": detail = "Combining notes"
                    case "final": detail = "Writing notes"
                    default: detail = "Loading notes model"
                    }
                    self.store.update(id) {
                        $0.stageDetail = detail
                        if let i = event.index, let n = event.total, n > 0 { $0.progress = Double(i) / Double(n) }
                    }
                default: break
                }
            }
        }
        try store.saveNotes(result.markdown, for: id)
        store.update(id) { if $0.autoTitle { $0.title = result.title } }
    }

    private func setStage(_ id: UUID, _ status: MeetingStatus, _ detail: String) {
        store.update(id) {
            $0.status = status
            $0.stageDetail = detail
            $0.progress = nil
        }
    }

    nonisolated private static func diarize(_ audio: URL, settings: DiarizationSettings) async -> Result<[SpeakerSegment], Error> {
        do {
            let diarizer = try DiarizerFactory.diarizer(for: settings)
            return .success(try await diarizer.diarize(audioURL: audio))
        } catch {
            return .failure(error)
        }
    }
}
