import Foundation

/// Streaming 16-bit PCM mono WAV writer. Not thread-safe: use from one queue.
final class WAVWriter {
    static let headerSize = 44

    let url: URL
    let sampleRate: Int
    private let handle: FileHandle
    private(set) var sampleCount = 0
    private var finished = false

    init(url: URL, sampleRate: Int = 16000) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataBytes: 0, sampleRate: sampleRate))
    }

    var duration: Double { Double(sampleCount) / Double(sampleRate) }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !finished, !samples.isEmpty else { return }
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                let v = max(-1, min(1, samples[i]))
                out[i] = Int16(v * 32767).littleEndian
            }
        }
        try? handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Pads with silence so the next appended sample lands at `index` (no-op if already past it).
    func fill(toSample index: Int) {
        var missing = index - sampleCount
        guard missing > 0 else { return }
        let block = [Float](repeating: 0, count: min(missing, 16000))
        while missing > 0 {
            let n = min(missing, block.count)
            block.withUnsafeBufferPointer { append(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            missing -= n
        }
    }

    func finish() throws {
        guard !finished else { return }
        finished = true
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: sampleCount * 2, sampleRate: sampleRate))
        try handle.close()
    }

    static func header(dataBytes: Int, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        return d
    }
}

/// Chunked reader for WAV files produced by `WAVWriter` (16-bit PCM mono, 44-byte header).
final class WAVReader {
    private let handle: FileHandle
    let sampleRate: Int
    let sampleCount: Int

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: WAVWriter.headerSize) ?? Data()
        guard header.count == WAVWriter.headerSize, header.prefix(4) == Data("RIFF".utf8) else {
            throw MinutesError.audio("\(url.lastPathComponent) is not a Minutes WAV file")
        }
        func u32(_ o: Int) -> Int { Int(header[o]) | Int(header[o + 1]) << 8 | Int(header[o + 2]) << 16 | Int(header[o + 3]) << 24 }
        sampleRate = u32(24)
        let fileBytes = Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        sampleCount = max(0, (fileBytes - WAVWriter.headerSize) / 2)
    }

    /// Next `count` samples as floats; empty at end of file.
    func read(_ count: Int) -> [Float] {
        guard let data = try? handle.read(upToCount: count * 2), !data.isEmpty else { return [] }
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }

    deinit { try? handle.close() }
}

enum MinutesError: LocalizedError {
    case audio(String)
    case engine(String)
    case diarization(String)
    case permission(String)

    var errorDescription: String? {
        switch self {
        case .audio(let m): return "Audio: \(m)"
        case .engine(let m): return "Engine: \(m)"
        case .diarization(let m): return "Diarization: \(m)"
        case .permission(let m): return m
        }
    }
}
