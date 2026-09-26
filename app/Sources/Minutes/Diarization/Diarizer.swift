import Foundation

struct SpeakerSegment: Codable, Hashable {
    let speaker: Int
    let start: Double
    let end: Double
}

/// The `diarization` block of a model profile.
struct DiarizationSettings: Codable, Hashable {
    var backend: String = "fluidaudio-nemotron3"
    var preset: String = "fast128"
    var threshold: Double = 0.5
}

/// Who spoke when. Implementations must be safe to call from any task; calls may be serialized internally.
protocol Diarizer: AnyObject {
    var settings: DiarizationSettings { get }
    /// Downloads (if needed) and loads the model. `progress` receives 0...1.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws
    /// Speaker segments for a 16 kHz mono file, speaker ids in arrival order.
    func diarize(audioURL: URL) async throws -> [SpeakerSegment]
}

enum DiarizerFactory {
    private static var cache: [String: Diarizer] = [:]
    private static let lock = NSLock()

    /// One loaded diarizer per settings value, reused across meetings.
    static func diarizer(for settings: DiarizationSettings) throws -> Diarizer {
        let key = "\(settings.backend)|\(settings.preset)|\(settings.threshold)"
        lock.lock()
        defer { lock.unlock() }
        if let d = cache[key] { return d }
        let d: Diarizer
        switch settings.backend {
        case "fluidaudio-nemotron3":
            d = try FluidAudioDiarizer(settings: settings)
        case "none":
            d = NoDiarizer(settings: settings)
        default:
            throw MinutesError.diarization("unknown diarization backend \(settings.backend)")
        }
        cache[key] = d
        return d
    }
}

/// Everything is one speaker; used when a profile sets `"backend": "none"`.
final class NoDiarizer: Diarizer {
    let settings: DiarizationSettings
    init(settings: DiarizationSettings) { self.settings = settings }
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws { progress?(1) }
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] { [] }
}
