import AVFoundation
import Foundation

/// Converts any audio or video file AVFoundation can read into a 16 kHz mono 16-bit WAV.
enum AudioImporter {
    static let sampleRate = 16000

    static let supportedExtensions = ["wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov", "m4v"]

    /// Returns the duration in seconds of the written WAV.
    @discardableResult
    static func convert(_ source: URL, to destination: URL, progress: ((Double) -> Void)? = nil) async throws -> Double {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MinutesError.audio("\(source.lastPathComponent) has no audio track") }
        let total = try await asset.load(.duration).seconds

        return try await Task.detached(priority: .userInitiated) {
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MinutesError.audio("cannot decode \(source.lastPathComponent)") }
            reader.add(output)
            guard reader.startReading() else {
                throw MinutesError.audio(reader.error?.localizedDescription ?? "cannot read \(source.lastPathComponent)")
            }
            let writer = try WAVWriter(url: destination, sampleRate: sampleRate)
            var lastReport = 0.0
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                floats.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                writer.append(floats)
                if let progress, total > 0, writer.duration - lastReport > 5 {
                    lastReport = writer.duration
                    progress(min(1, writer.duration / total))
                }
            }
            if reader.status == .failed {
                throw MinutesError.audio(reader.error?.localizedDescription ?? "decode failed")
            }
            try writer.finish()
            progress?(1)
            return writer.duration
        }.value
    }
}
