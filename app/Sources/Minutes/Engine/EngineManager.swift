import Foundation

/// Owns the engine process: start on demand, restart after crashes, profile selection, model preparation.
@MainActor
final class EngineManager: ObservableObject {
    enum State: Equatable {
        case stopped, starting, ready, failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting"
            case .ready: return "Ready"
            case .failed(let m): return "Failed: \(m)"
            }
        }
    }

    static let profileKey = "selectedProfile"

    @Published private(set) var state: State = .stopped
    @Published private(set) var profiles: [EngineProfile] = []
    @Published private(set) var activeProfile: EngineProfile?

    private var process: EngineProcess?
    private var client: EngineClient?
    private var startTask: Task<EngineClient, Error>?

    var selectedProfileName: String {
        get { UserDefaults.standard.string(forKey: Self.profileKey) ?? "default" }
        set { UserDefaults.standard.set(newValue, forKey: Self.profileKey) }
    }

    var diarizationSettings: DiarizationSettings { activeProfile?.diarization ?? DiarizationSettings() }

    /// Returns a client for a running engine, starting it if needed. Concurrent callers share one start.
    func ensureReady() async throws -> EngineClient {
        if let client, state == .ready { return client }
        if startTask == nil {
            state = .starting
            startTask = Task { try await self.launch() }
        }
        do {
            let c = try await startTask!.value
            return c
        } catch {
            startTask = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func launch() async throws -> EngineClient {
        let proc = EngineProcess()
        proc.onExit = { [weak self] code in
            Task { @MainActor in self?.engineExited(code) }
        }
        process = proc
        let requested = selectedProfileName
        var c: EngineClient
        do {
            c = try await proc.start(profile: requested)
        } catch where requested != "default" {
            proc.stop()
            selectedProfileName = "default"
            let retry = EngineProcess()
            retry.onExit = proc.onExit
            process = retry
            c = try await retry.start(profile: "default")
        }
        client = c
        let health = try await c.health()
        activeProfile = health.profile
        profiles = (try? await c.profiles().profiles) ?? [health.profile]
        state = .ready
        return c
    }

    private func engineExited(_ code: Int32) {
        client = nil
        startTask = nil
        process = nil
        let tail = EngineProcess.tailLog(lines: 3).trimmingCharacters(in: .whitespacesAndNewlines)
        state = .failed("engine exited with code \(code)" + (tail.isEmpty ? "" : ": \(tail)"))
    }

    func restart() async {
        stop()
        _ = try? await ensureReady()
    }

    func stop() {
        process?.stop()
        process = nil
        client = nil
        startTask = nil
        state = .stopped
    }

    func refreshProfiles() async {
        guard let c = try? await ensureReady(), let r = try? await c.profiles() else { return }
        profiles = r.profiles
        activeProfile = r.profiles.first { $0.name == r.active } ?? activeProfile
    }

    func selectProfile(_ name: String) async throws {
        let c = try await ensureReady()
        activeProfile = try await c.selectProfile(name)
        selectedProfileName = name
    }

    /// Downloads and loads every model of the active profile (engine ASR + LLM, CoreML diarizer).
    func prepareModels(onStatus: @escaping @MainActor (String, Double?) -> Void) async throws {
        onStatus("Starting engine", nil)
        let c = try await ensureReady()
        let diarizer = try DiarizerFactory.diarizer(for: diarizationSettings)
        onStatus("Downloading speaker model (Nemotron 3 Diarization)", 0)
        try await diarizer.prepare { p in Task { @MainActor in onStatus("Downloading speaker model (Nemotron 3 Diarization)", p) } }
        try await c.fetchModels { event in
            Task { @MainActor in
                switch event.stage {
                case "fetch": onStatus("Downloading \(event.repo ?? "model")", nil)
                case "load_asr": onStatus("Loading speech recognition model", nil)
                case "load_llm": onStatus("Loading notes model", nil)
                default: break
                }
            }
        }
        onStatus("Models ready", 1)
    }
}
