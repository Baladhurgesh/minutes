import CoreML
import FluidAudio
import Foundation

/// NVIDIA Nemotron 3 Diarization (8-speaker Sortformer) via FluidAudio's CoreML conversion.
/// Models download on first use to ~/Library/Application Support/FluidAudio/Models.
final class FluidAudioDiarizer: Diarizer, @unchecked Sendable {
    let settings: DiarizationSettings
    private let config: Nemotron3Config
    private var diarizer: Nemotron3Diarizer?
    private let loadLock = AsyncLock()
    private let runLock = NSLock()

    init(settings: DiarizationSettings) throws {
        guard let config = Nemotron3Config.preset(named: settings.preset) else {
            throw MinutesError.diarization("unknown Nemotron 3 preset \(settings.preset)")
        }
        self.settings = settings
        self.config = config
    }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        try await loadLock.run {
            if diarizer != nil {
                progress?(1)
                return
            }
            do {
                let models = try await Nemotron3Models.loadFromHuggingFace(
                    config: config, computeUnits: .all,
                    progressHandler: { p in progress?(p.fractionCompleted) })
                diarizer = Nemotron3Diarizer(config: config, models: models)
                progress?(1)
            } catch {
                throw MinutesError.diarization("could not load Nemotron 3 (\(settings.preset)): \(error.localizedDescription)")
            }
        }
    }

    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        try await prepare(progress: nil)
        guard let diarizer else { throw MinutesError.diarization("model not loaded") }
        let threshold = Float(settings.threshold)
        let lock = runLock
        return try await Task.detached(priority: .userInitiated) {
            try lock.withLock {
                let audio = try AudioConverter().resampleAudioFile(audioURL)
                guard !audio.isEmpty else { return [] }
                let (probabilities, frames) = try diarizer.processComplete(audio)
                return Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames, threshold: threshold)
                    .map { SpeakerSegment(speaker: $0.speakerIndex, start: Double($0.startSeconds), end: Double($0.endSeconds)) }
            }
        }.value
    }
}

/// Serializes async critical sections (one model load at a time).
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
