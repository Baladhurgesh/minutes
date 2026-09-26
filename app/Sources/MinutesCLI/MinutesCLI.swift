import Foundation

/// Headless driver for the same code the app runs; used for end-to-end tests.
@main
struct MinutesCLI {
    static let usage = """
        minutes-cli <command> [options]

          import <input> <out.wav>                      convert any audio/video to 16 kHz mono WAV
          diarize <audio> [--preset P] [--threshold T] [--out segments.json]
          record <out-dir> [--seconds N] [--no-system]  record mic (+ system audio) then mix
          run <audio> [--profile NAME] [--out DIR]      full pipeline: import, diarize + transcribe, align, notes
        """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print(usage)
            exit(2)
        }
        args.removeFirst()
        do {
            switch command {
            case "import": try await importCommand(args)
            case "diarize": try await diarizeCommand(args)
            case "record": try await recordCommand(args)
            case "run": try await runCommand(args)
            default:
                print(usage)
                exit(2)
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func positional(_ args: [String]) -> [String] {
        var out: [String] = []
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if a.hasPrefix("--") {
                skip = !["--no-system", "--no-notes"].contains(a)
                continue
            }
            out.append(a)
        }
        return out
    }

    static func importCommand(_ args: [String]) async throws {
        let pos = positional(args)
        guard pos.count == 2 else { throw MinutesError.audio("usage: import <input> <out.wav>") }
        let start = Date()
        let duration = try await AudioImporter.convert(URL(fileURLWithPath: pos[0]), to: URL(fileURLWithPath: pos[1]))
        print(String(format: "wrote %@ (%.1fs audio in %.2fs)", pos[1], duration, Date().timeIntervalSince(start)))
    }

    static func diarizeCommand(_ args: [String]) async throws {
        guard let path = positional(args).first else { throw MinutesError.audio("usage: diarize <audio>") }
        var settings = DiarizationSettings()
        if let p = option("--preset", in: args) { settings.preset = p }
        if let t = option("--threshold", in: args).flatMap(Double.init) { settings.threshold = t }
        let diarizer = try DiarizerFactory.diarizer(for: settings)
        var t0 = Date()
        try await diarizer.prepare(progress: ProgressPrinter(label: "diarization model").report)
        fputs(String(format: "\nmodel ready in %.1fs\n", Date().timeIntervalSince(t0)), stderr)
        t0 = Date()
        let segments = try await diarizer.diarize(audioURL: URL(fileURLWithPath: path))
        let speakers = Set(segments.map(\.speaker))
        print(String(format: "%d segments, %d speakers in %.2fs", segments.count, speakers.count, Date().timeIntervalSince(t0)))
        for s in segments.prefix(40) {
            print(String(format: "  spk%d %7.2f - %7.2f", s.speaker, s.start, s.end))
        }
        if let out = option("--out", in: args) {
            let data = try JSONEncoder().encode(["segments": segments])
            try data.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        }
    }

    @MainActor
    static func recordCommand(_ args: [String]) async throws {
        guard let dir = positional(args).first else { throw MinutesError.audio("usage: record <out-dir>") }
        let seconds = option("--seconds", in: args).flatMap(Double.init) ?? 5
        let recorder = Recorder()
        try await recorder.start(directory: URL(fileURLWithPath: dir), captureSystemAudio: !args.contains("--no-system"),
                                 inputDeviceUID: option("--device", in: args))
        print("recording \(seconds)s (system audio: \(recorder.capturingSystemAudio))")
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await Task.sleep(nanoseconds: 500_000_000)
            print(String(format: "  %.1fs  mic %.3f  system %.3f", recorder.elapsed, recorder.micLevel, recorder.systemLevel))
        }
        let result = try await recorder.stop()
        print(String(format: "mixed %.2fs -> %@", result.duration, result.mixedURL.path))
        for w in result.warnings { print("warning: \(w)") }
    }

    @MainActor
    static func runCommand(_ args: [String]) async throws {
        guard let input = positional(args).first else { throw MinutesError.audio("usage: run <audio> [--profile P] [--out DIR]") }
        let source = URL(fileURLWithPath: input)
        let store = MeetingStore(root: option("--out", in: args).map { URL(fileURLWithPath: $0) } ?? MeetingStore.defaultRoot)
        let engine = EngineManager()
        if let p = option("--profile", in: args) { engine.selectedProfileName = p }
        let pipeline = MeetingPipeline(store: store, engine: engine)
        defer { engine.stop() }

        let t0 = Date()
        let meeting = try store.create(title: source.deletingPathExtension().lastPathComponent, source: source.lastPathComponent,
                                       status: .importing)
        let id = meeting.id
        let duration = try await AudioImporter.convert(source, to: store.audioURL(id))
        store.update(id) { $0.duration = duration }
        print(String(format: "meeting %@ (%.1fs audio) -> %@", id.uuidString, duration, store.directory(for: id).path))

        let monitor = Task { @MainActor in
            var lastStage = ""
            var printed = 0
            while !Task.isCancelled {
                if let m = store.meeting(id) {
                    let stage = "\(m.status.label): \(m.stageDetail ?? "")"
                    if stage != lastStage {
                        print(String(format: "\n[%6.1fs] %@", Date().timeIntervalSince(t0), stage))
                        lastStage = stage
                    }
                }
                if let live = pipeline.liveNotes[id], live.count > printed {
                    print(live.dropFirst(printed), terminator: "")
                    fflush(stdout)
                    printed = live.count
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await pipeline.processNow(id)
        monitor.cancel()

        guard let done = store.meeting(id) else { return }
        print(String(format: "\n\n== %@ in %.1fs: %@", done.status.label, Date().timeIntervalSince(t0), done.title))
        if let error = done.error { throw MinutesError.engine(error) }
        for w in done.warnings { print("warning: \(w)") }
        if let t = store.transcript(id) {
            print("\n-- transcript (\(t.speakers.count) speakers, \(t.segments.count) diarization segments)")
            for turn in t.turns { print("[\(TimeFormat.clock(turn.start))] \(done.speakerName(turn.speaker)): \(turn.text)") }
        }
        print("\n-- notes.md\n\(store.notes(id) ?? "")")
    }
}
