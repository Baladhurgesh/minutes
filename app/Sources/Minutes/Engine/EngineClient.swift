import Foundation

/// Any JSON value (profile `llm.config` is free-form).
enum JSONValue: Codable, Hashable, CustomStringConvertible {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var description: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return String(b)
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array(let a): return "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { "\($0): \(o[$0]!)" }.joined(separator: ", ") + "}"
        }
    }
}

struct EngineProfile: Codable, Identifiable, Hashable {
    struct LLM: Codable, Hashable {
        var model: String
        var config: [String: JSONValue]
        var kernels: [String: String]
    }
    struct ASR: Codable, Hashable {
        var model: String
        var dtype: String
        var chunkDuration: Double
        enum CodingKeys: String, CodingKey { case model, dtype, chunkDuration = "chunk_duration" }
    }

    var name: String
    var description: String
    var llm: LLM
    var asr: ASR
    var diarization: DiarizationSettings
    var path: String?
    var id: String { name }

    /// Non-null config entries, e.g. "bits: 8, keep_high: [lm_head]".
    var llmConfigSummary: String {
        let parts = llm.config.keys.sorted().compactMap { k -> String? in
            guard let v = llm.config[k], v != .null, v != .array([]) else { return nil }
            return "\(k): \(v)"
        }
        return parts.isEmpty ? "bf16, stock" : parts.joined(separator: ", ")
    }
}

struct EngineHealth: Decodable {
    let status: String
    let version: String
    let profile: EngineProfile
    let asrLoaded: Bool
    let llmLoaded: Bool
    enum CodingKeys: String, CodingKey {
        case status, version, profile, asrLoaded = "asr_loaded", llmLoaded = "llm_loaded"
    }
}

struct ProfilesResponse: Decodable {
    let active: String
    let profiles: [EngineProfile]
}

/// One Server-Sent Event from a long-running engine job.
struct EngineEvent: Decodable {
    let type: String
    var stage: String?
    var value: Double?
    var text: String?
    var index: Int?
    var total: Int?
    var repo: String?
    var message: String?
}

struct TranscribeResult: Decodable {
    let words: [Word]
    let elapsed: Double
    let model: String
}

struct NotesResult: Decodable {
    let title: String
    let markdown: String
    let elapsed: Double
}

struct EngineClient: Sendable {
    let baseURL: URL
    let token: String

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3600
        c.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func check(_ response: URLResponse, _ data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw MinutesError.engine("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw MinutesError.engine("HTTP \(http.statusCode) \(detail)")
        }
    }

    private func call<T: Decodable>(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> T {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, response) = try await Self.session.data(for: request(path, method: method, body: body))
        try check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encodeBody<B: Encodable>(_ body: B) throws -> Data { try JSONEncoder().encode(body) }

    /// Streams a job; `onEvent` gets progress/stage/token events; returns the raw JSON of the final "done" event.
    private func stream(_ path: String, body: Data, onEvent: @escaping (EngineEvent) -> Void) async throws -> Data {
        let (bytes, response) = try await Self.session.bytes(for: request(path, method: "POST", body: body))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw MinutesError.engine("HTTP \(http.statusCode) \(text)")
        }
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
            let event = try decoder.decode(EngineEvent.self, from: data)
            switch event.type {
            case "done": return data
            case "error": throw MinutesError.engine(event.message ?? "unknown engine error")
            default: onEvent(event)
            }
        }
        try Task.checkCancellation()
        throw MinutesError.engine("the engine closed the stream without a result (did it crash? see the engine log)")
    }

    func health() async throws -> EngineHealth { try await call("health") }

    func profiles() async throws -> ProfilesResponse { try await call("profiles") }

    @discardableResult
    func selectProfile(_ name: String) async throws -> EngineProfile {
        struct R: Decodable { let profile: EngineProfile }
        let r: R = try await call("profiles/select", method: "POST", json: ["name": name])
        return r.profile
    }

    func reload() async throws {
        struct R: Decodable { let status: String }
        let _: R = try await call("reload", method: "POST")
    }

    func fetchModels(onEvent: @escaping (EngineEvent) -> Void) async throws {
        _ = try await stream("fetch", body: Data("{}".utf8), onEvent: onEvent)
    }

    func transcribe(audioURL: URL, onEvent: @escaping (EngineEvent) -> Void) async throws -> TranscribeResult {
        struct Body: Encodable { let audio_path: String }
        let data = try await stream("transcribe", body: try encodeBody(Body(audio_path: audioURL.path)), onEvent: onEvent)
        return try JSONDecoder().decode(TranscribeResult.self, from: data)
    }

    func align(words: [Word], segments: [SpeakerSegment]) async throws -> [Turn] {
        struct Body: Encodable { let words: [Word]; let segments: [SpeakerSegment] }
        struct R: Decodable { let turns: [Turn] }
        var r = request("align", method: "POST", body: try encodeBody(Body(words: words, segments: segments)))
        r.timeoutInterval = 600
        let (data, response) = try await Self.session.data(for: r)
        try check(response, data)
        return try JSONDecoder().decode(R.self, from: data).turns
    }

    func notes(turns: [Turn], speakerNames: [Int: String], onEvent: @escaping (EngineEvent) -> Void) async throws -> NotesResult {
        struct Body: Encodable { let turns: [Turn]; let speaker_names: [String: String] }
        let names = Dictionary(uniqueKeysWithValues: speakerNames.map { (String($0.key), $0.value) })
        let data = try await stream("notes", body: try encodeBody(Body(turns: turns, speaker_names: names)), onEvent: onEvent)
        return try JSONDecoder().decode(NotesResult.self, from: data)
    }
}
