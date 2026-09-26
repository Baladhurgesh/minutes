import Foundation

/// One directory per meeting under `root`: meta.json, audio.wav (+ mic.wav / system.wav), transcript.json, notes.md.
@MainActor
final class MeetingStore: ObservableObject {
    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutes/meetings", isDirectory: true)
    }

    @Published private(set) var meetings: [Meeting] = []
    let root: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(root: URL = MeetingStore.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audioURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("audio.wav") }
    func transcriptURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("transcript.json") }
    func notesURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("notes.md") }
    private func metaURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("meta.json") }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        meetings = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
        recoverInterrupted()
    }

    /// Meetings left mid-flight by a quit or crash: salvage recordings, requeue processing.
    private func recoverInterrupted() {
        for m in meetings {
            switch m.status {
            case .recording:
                let dir = directory(for: m.id)
                let mic = dir.appendingPathComponent("mic.wav")
                let system = dir.appendingPathComponent("system.wav")
                if let duration = try? RecordingSession.mix(
                    mic, FileManager.default.fileExists(atPath: system.path) ? system : nil, into: audioURL(m.id)),
                   duration > 1 {
                    update(m.id) {
                        $0.status = .queued
                        $0.duration = duration
                        $0.warnings.append("Recording was interrupted; recovered \(TimeFormat.clock(duration)).")
                    }
                } else {
                    update(m.id) { $0.status = .failed; $0.error = "Recording was interrupted before any audio was saved." }
                }
            case .importing:
                update(m.id) { $0.status = .failed; $0.error = "Import was interrupted. Import the file again." }
            case .transcribing, .aligning, .summarizing:
                update(m.id) { $0.status = .queued; $0.progress = nil }
            default:
                break
            }
        }
    }

    @discardableResult
    func create(title: String? = nil, source: String, status: MeetingStatus) throws -> Meeting {
        let now = Date()
        let m = Meeting(id: UUID(), title: title ?? Meeting.defaultTitle(for: now), createdAt: now, source: source,
                        status: status)
        try FileManager.default.createDirectory(at: directory(for: m.id), withIntermediateDirectories: true)
        save(m)
        return m
    }

    func save(_ meeting: Meeting) {
        if let data = try? encoder.encode(meeting) {
            try? data.write(to: metaURL(meeting.id), options: .atomic)
        }
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.createdAt > $1.createdAt }
        }
    }

    func update(_ id: UUID, _ mutate: (inout Meeting) -> Void) {
        guard var m = meeting(id) else { return }
        mutate(&m)
        save(m)
    }

    func transcript(_ id: UUID) -> Transcript? {
        guard let data = try? Data(contentsOf: transcriptURL(id)) else { return nil }
        return try? decoder.decode(Transcript.self, from: data)
    }

    func saveTranscript(_ transcript: Transcript, for id: UUID) throws {
        try encoder.encode(transcript).write(to: transcriptURL(id), options: .atomic)
        objectWillChange.send()
    }

    func notes(_ id: UUID) -> String? { try? String(contentsOf: notesURL(id), encoding: .utf8) }

    func saveNotes(_ markdown: String, for id: UUID) throws {
        try markdown.write(to: notesURL(id), atomically: true, encoding: .utf8)
        objectWillChange.send()
    }

    /// Moves the meeting folder (audio, transcript, notes) to the Trash so it can be restored.
    func delete(_ id: UUID) {
        let dir = directory(for: id)
        if (try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: dir)
        }
        meetings.removeAll { $0.id == id }
    }

    /// Notes followed by the speaker-labelled transcript, for export.
    func exportMarkdown(_ id: UUID) -> String {
        guard let m = meeting(id) else { return "" }
        var out = notes(id) ?? "# \(m.title)\n"
        if let t = transcript(id) {
            out += "\n\n## Transcript\n\n"
            for turn in t.turns {
                out += "**\(m.speakerName(turn.speaker))** [\(TimeFormat.clock(turn.start))]: \(turn.text)\n\n"
            }
        }
        return out
    }
}
