import AVFoundation
import Foundation

/// Converts any audio or video file AVFoundation can read into a 16 kHz mono 16-bit WAV.
enum AudioImporter {
    static let sampleRate = 16000

    /// Returns the duration in seconds of the written WAV.
    @discardableResult
    static func convert(_ source: URL, to destination: URL, progress: ((Double) -> Void)? = nil) async throws -> Double {
        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MinutesError.audio("\(source.lastPathComponent) can't be read on this Mac. Convert it to MP3 or M4A and upload again.")
        }
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
