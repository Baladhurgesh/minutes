import Foundation

struct Word: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Double = 1
}

struct Turn: Codable, Hashable {
    var speaker: Int
    var start: Double
    var end: Double
    var text: String
    var words: [Word]
}

struct Transcript: Codable {
    var turns: [Turn]
    var segments: [SpeakerSegment]
    var asrModel: String?
    var diarization: DiarizationSettings?

    var speakers: [Int] { Array(Set(turns.map(\.speaker))).sorted() }
}

enum MeetingStatus: String, Codable {
    case recording, importing, queued, transcribing, aligning, summarizing, done, failed

    var isWorking: Bool {
        switch self {
        case .importing, .queued, .transcribing, .aligning, .summarizing: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .importing: return "Importing"
        case .queued: return "Queued"
        case .transcribing: return "Transcribing"
        case .aligning: return "Aligning speakers"
        case .summarizing: return "Writing notes"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

struct Meeting: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var autoTitle: Bool = true
    var createdAt: Date
    var duration: Double = 0
    /// "recording" or the imported file's name.
    var source: String
    var status: MeetingStatus
    var progress: Double?
    var stageDetail: String?
    var error: String?
    /// Speaker id (as a string, for JSON) -> display name.
    var speakerNames: [String: String] = [:]
    var profile: String?
    var warnings: [String] = []

    func speakerName(_ speaker: Int) -> String {
        if let name = speakerNames[String(speaker)], !name.isEmpty { return name }
        return "Speaker \(speaker + 1)"
    }

    var speakerNamesByID: [Int: String] {
        Dictionary(uniqueKeysWithValues: speakerNames.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Meeting, \(f.string(from: date))"
    }
}

enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
