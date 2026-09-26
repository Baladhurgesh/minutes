import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct RecordingResult {
    let duration: Double
    let mixedURL: URL
    let micURL: URL
    let systemURL: URL?
    let warnings: [String]
}

/// Converts PCM buffers of any format to 16 kHz mono and writes them time-aligned to the session start.
final class TrackWriter {
    private static let rate = 16000.0
    private static let gapTolerance = 1600  // 100 ms: smaller drifts come from resampler latency, not real gaps

    let writer: WAVWriter
    private let sessionStart: Double
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let levelLock = NSLock()
    private var _level: Float = 0

    init(url: URL, sessionStart: Double) throws {
        writer = try WAVWriter(url: url, sampleRate: Int(Self.rate))
        self.sessionStart = sessionStart
    }

    var level: Float {
        levelLock.lock(); defer { levelLock.unlock() }
        return _level
    }

    /// `hostSeconds`: host-clock time of the buffer's first frame.
    func write(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return }
        let expected = Int((hostSeconds - sessionStart) * Self.rate)
        if writer.sampleCount == 0 || expected - writer.sampleCount > Self.gapTolerance {
            writer.fill(toSample: expected)
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        writer.append(samples)
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        levelLock.lock(); _level = rms; levelLock.unlock()
    }
}

/// One recording: microphone via AVAudioEngine, system audio via ScreenCaptureKit, each to its own track.
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let directory: URL
    let sessionStart: Double
    let mic: TrackWriter
    private(set) var system: TrackWriter?
    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private let systemQueue = DispatchQueue(label: "minutes.system-audio")
    private var systemClock: (firstPTS: Double, firstHost: Double)?
    private(set) var warnings: [String] = []

    var micURL: URL { directory.appendingPathComponent("mic.wav") }
    var systemURL: URL { directory.appendingPathComponent("system.wav") }
    var mixedURL: URL { directory.appendingPathComponent("audio.wav") }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionStart = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        mic = try TrackWriter(url: directory.appendingPathComponent("mic.wav"), sessionStart: sessionStart)
    }

    func start(captureSystemAudio: Bool, inputDeviceUID: String?) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MinutesError.permission(
                "Microphone access is off. Enable Minutes in System Settings > Privacy & Security > Microphone.")
        }
        try startMicrophone(deviceUID: inputDeviceUID)
        if captureSystemAudio {
            do {
                try await startSystemAudio()
            } catch {
                warnings.append(
                    "System audio was not captured (\(error.localizedDescription)). Allow Minutes under System Settings > "
                        + "Privacy & Security > Screen & System Audio Recording, then record again.")
            }
        }
    }

    private func startMicrophone(deviceUID: String?) throws {
        let input = engine.inputNode
        if let deviceUID, var deviceID = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { warnings.append("Could not select the chosen microphone; using the system default.") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MinutesError.audio("no microphone input available")
        }
        let mic = self.mic
        let start = sessionStart
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : start
            mic.write(buffer, hostSeconds: host)
        }
        engine.prepare()
        try engine.start()
    }

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw MinutesError.audio("no display to attach capture to") }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // ScreenCaptureKit always needs a video stream; keep it tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        system = try TrackWriter(url: systemURL, sessionStart: sessionStart)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: systemQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let system,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr
        else { return }
        // Map the stream's presentation clock onto the host clock at the first buffer, so later gaps
        // (ScreenCaptureKit stops delivering while nothing plays) become silence instead of shifting time.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if systemClock == nil {
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            systemClock = (pts, now - Double(frames) / format.sampleRate)
        }
        let host = systemClock!.firstHost + (pts - systemClock!.firstPTS)
        system.write(pcm, hostSeconds: host)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        warnings.append("System audio capture stopped: \(error.localizedDescription)")
    }

    func stop() async throws -> RecordingResult {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let stream {
            try? await stream.stopCapture()
        }
        systemQueue.sync {}
        try mic.writer.finish()
        try system?.writer.finish()
        let systemFile = (system?.writer.sampleCount ?? 0) > 0 ? systemURL : nil
        let duration = try Self.mix(micURL, systemFile, into: mixedURL)
        return RecordingResult(duration: duration, mixedURL: mixedURL, micURL: micURL, systemURL: systemFile,
                               warnings: warnings)
    }

    /// Sums both tracks (the shorter one padded with silence) into a mono 16 kHz WAV.
    static func mix(_ a: URL, _ b: URL?, into out: URL) throws -> Double {
        let ra = try WAVReader(url: a)
        let rb = try b.map { try WAVReader(url: $0) }
        let writer = try WAVWriter(url: out, sampleRate: ra.sampleRate)
        let chunk = 16000 * 10
        while true {
            let x = ra.read(chunk)
            let y = rb?.read(chunk) ?? []
            if x.isEmpty && y.isEmpty { break }
            var mixed = [Float](repeating: 0, count: max(x.count, y.count))
            for i in 0..<x.count { mixed[i] = x[i] }
            for i in 0..<y.count { mixed[i] += y[i] }
            writer.append(mixed)
        }
        try writer.finish()
        return writer.duration
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var capturingSystemAudio = false
    @Published private(set) var directory: URL?

    private var session: RecordingSession?
    private var timer: Timer?
    private var startedAt: Date?

    func start(directory: URL, captureSystemAudio: Bool, inputDeviceUID: String?) async throws {
        guard session == nil else { return }
        let session = try RecordingSession(directory: directory)
        try await session.start(captureSystemAudio: captureSystemAudio, inputDeviceUID: inputDeviceUID)
        self.session = session
        self.directory = directory
        capturingSystemAudio = session.system != nil
        startedAt = Date()
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let session, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        micLevel = session.mic.level
        systemLevel = session.system?.level ?? 0
    }

    func stop() async throws -> RecordingResult {
        guard let session else { throw MinutesError.audio("not recording") }
        timer?.invalidate()
        timer = nil
        isRecording = false
        self.session = nil
        micLevel = 0
        systemLevel = 0
        return try await session.stop()
    }
}
