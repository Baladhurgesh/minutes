import Foundation

/// Launches the Python MLX engine (`python -m minutes_engine serve`) and waits for its ready line.
///
/// Python is looked up in this order: `MINUTES_ENGINE_PYTHON`; the engine bundled into the app by
/// scripts/bundle_engine.sh (Contents/Resources/engine/python); the dev checkout's `engine/.venv`
/// (Info.plist `MinutesEngineDevPath`, `MINUTES_ENGINE_DIR`, or this source file's repo).
final class EngineProcess: @unchecked Sendable {
    struct Location {
        let python: URL
        let bundled: Bool
    }

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutes", isDirectory: true)
    }
    static var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Minutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.log")
    }
    static var userProfilesDir: URL { appSupport.appendingPathComponent("profiles", isDirectory: true) }
    static var bundledModelCache: URL { appSupport.appendingPathComponent("models", isDirectory: true) }

    let token = UUID().uuidString
    private var process: Process?
    private var logHandle: FileHandle?
    var onExit: (@Sendable (Int32) -> Void)?

    static func locate() throws -> Location {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let p = env["MINUTES_ENGINE_PYTHON"], fm.isExecutableFile(atPath: p) {
            return Location(python: URL(fileURLWithPath: p), bundled: false)
        }
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("engine/python/bin/python3")
            if fm.isExecutableFile(atPath: bundled.path) { return Location(python: bundled, bundled: true) }
        }
        var devDirs: [String] = []
        if let d = env["MINUTES_ENGINE_DIR"] { devDirs.append(d) }
        if let d = Bundle.main.object(forInfoDictionaryKey: "MinutesEngineDevPath") as? String { devDirs.append(d) }
        devDirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../engine").standardized.path)
        for d in devDirs {
            let py = URL(fileURLWithPath: d).appendingPathComponent(".venv/bin/python")
            if fm.isExecutableFile(atPath: py.path) { return Location(python: py, bundled: false) }
        }
        throw MinutesError.engine(
            "could not find the Minutes engine. Run `uv sync` in engine/, or build a bundled app with scripts/bundle_engine.sh.")
    }

    static var profileDirs: [URL] {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("profiles"),
           FileManager.default.fileExists(atPath: res.path) { dirs.append(res) }
        if let dev = Bundle.main.object(forInfoDictionaryKey: "MinutesProfilesDevPath") as? String { dirs.append(URL(fileURLWithPath: dev)) }
        try? FileManager.default.createDirectory(at: userProfilesDir, withIntermediateDirectories: true)
        dirs.append(userProfilesDir)
        return dirs
    }

    /// Starts the engine and returns a client once it is listening.
    func start(profile: String) async throws -> EngineClient {
        let location = try Self.locate()
        let proc = Process()
        proc.executableURL = location.python
        var args = ["-m", "minutes_engine", "serve", "--port", "0", "--parent-pid", String(getpid()), "--profile", profile]
        for d in Self.profileDirs { args += ["--profiles-dir", d.path] }
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["MINUTES_ENGINE_TOKEN"] = token
        env["PYTHONUNBUFFERED"] = "1"
        if location.bundled {
            env["PYTHONNOUSERSITE"] = "1"
            env["PYTHONHOME"] = location.python.deletingLastPathComponent().deletingLastPathComponent().path
            if env["HF_HUB_CACHE"] == nil { env["HF_HUB_CACHE"] = Self.bundledModelCache.path }
        }
        proc.environment = env

        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: Self.logURL)
        logHandle = log
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = log
        proc.terminationHandler = { [weak self] p in self?.onExit?(p.terminationStatus) }
        try proc.run()
        process = proc

        let port = try await Self.waitForReady(stdout.fileHandleForReading, log: log, timeout: 120)
        return EngineClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token)
    }

    /// Copies the engine's stdout to the log for its whole life, yielding the port from the ready line.
    private static func waitForReady(_ handle: FileHandle, log: FileHandle, timeout: Double) async throws -> Int {
        let (ports, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        Task.detached {
            var announced = false
            do {
                for try await line in handle.bytes.lines {
                    log.write(Data((line + "\n").utf8))
                    if !announced, line.hasPrefix("MINUTES_ENGINE_READY"),
                       let p = line.split(separator: "=").last.flatMap({ Int($0) }) {
                        announced = true
                        continuation.yield(p)
                        continuation.finish()
                    }
                }
            } catch {}
            if !announced {
                continuation.finish(throwing: MinutesError.engine("the engine exited during startup; see \(logURL.path)"))
            }
        }
        return try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                for try await p in ports { return p }
                throw MinutesError.engine("the engine exited during startup; see \(logURL.path)")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MinutesError.engine("the engine did not start within \(Int(timeout))s; see \(logURL.path)")
            }
            let port = try await group.next()!
            group.cancelAll()
            return port
        }
    }

    func stop() {
        onExit = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }

    static func tailLog(lines: Int = 20) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
