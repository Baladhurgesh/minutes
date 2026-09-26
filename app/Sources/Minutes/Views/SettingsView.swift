import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelsSettings().tabItem { Label("Models", systemImage: "cpu") }
            AudioSettings().tabItem { Label("Audio", systemImage: "mic") }
            EngineSettings().tabItem { Label("Engine", systemImage: "gearshape.2") }
        }
        .frame(width: 560, height: 420)
    }
}

struct ModelsSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: EngineManager
    @State private var error: String?
    @State private var switching = false

    var body: some View {
        Form {
            Section {
                Picker("Profile", selection: Binding(
                    get: { engine.activeProfile?.name ?? engine.selectedProfileName },
                    set: { name in select(name) })) {
                    ForEach(engine.profiles) { p in Text(p.name).tag(p.name) }
                }
                .disabled(switching || engine.profiles.isEmpty)
                if let p = engine.activeProfile {
                    if !p.description.isEmpty { Text(p.description).font(.callout).foregroundStyle(.secondary) }
                    LabeledContent("Notes LLM", value: p.llm.model)
                    LabeledContent("LLM config", value: p.llmConfigSummary)
                    if !p.llm.kernels.isEmpty {
                        LabeledContent("visai kernels", value: p.llm.kernels.keys.sorted().joined(separator: ", "))
                    }
                    LabeledContent("Speech recognition", value: p.asr.model)
                    LabeledContent("Speakers", value: "Nemotron 3 Diarization, \(p.diarization.preset) preset")
                    if let path = p.path { LabeledContent("File", value: path).lineLimit(1).truncationMode(.middle) }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            } footer: {
                Text("Profiles are JSON files. Drop visai-optimized profiles (quantization config plus promoted kernels) "
                     + "into the profiles folder, then reload.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Open Profiles Folder") {
                        try? FileManager.default.createDirectory(at: EngineProcess.userProfilesDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(EngineProcess.userProfilesDir)
                    }
                    Button("Reload Profiles") { Task { await engine.refreshProfiles() } }
                    Spacer()
                    Button("Download Models...") { model.showModelSetup = true }
                }
            }
        }
        .formStyle(.grouped)
        .task { await engine.refreshProfiles() }
    }

    private func select(_ name: String) {
        switching = true
        error = nil
        Task {
            do { try await engine.selectProfile(name) } catch { self.error = error.localizedDescription }
            switching = false
        }
    }
}

struct AudioSettings: View {
    @AppStorage(AppModel.captureSystemAudioKey) private var captureSystemAudio = true
    @AppStorage(AppModel.inputDeviceKey) private var inputDeviceUID = ""
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Picker("Microphone", selection: $inputDeviceUID) {
                Text("System default").tag("")
                ForEach(devices) { d in Text(d.name).tag(d.id) }
            }
            Toggle("Also record system audio (Zoom, Meet, Teams)", isOn: $captureSystemAudio)
            Text("System audio uses the Screen & System Audio Recording permission. No video is captured. Use headphones "
                 + "on calls so the microphone does not pick up the other side twice.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.inputDevices() }
    }
}

struct EngineSettings: View {
    @EnvironmentObject var engine: EngineManager

    var body: some View {
        Form {
            LabeledContent("Status", value: engine.state.label).lineLimit(3)
            LabeledContent("Log", value: EngineProcess.logURL.path).lineLimit(1).truncationMode(.middle)
            LabeledContent("Engine", value: (try? EngineProcess.locate().python.path) ?? "not found")
                .lineLimit(1).truncationMode(.middle)
            HStack {
                Button("Restart Engine") { Task { await engine.restart() } }
                Button("Open Log") { NSWorkspace.shared.open(EngineProcess.logURL) }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelSetupView: View {
    @EnvironmentObject var engine: EngineManager
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var progress: Double?
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download the local models").font(.title2.bold())
            Text("Minutes runs entirely on this Mac. It needs these models once (about 4 GB):")
            VStack(alignment: .leading, spacing: 6) {
                Label("Parakeet TDT 0.6b v3: speech recognition", systemImage: "waveform")
                Label("Nemotron 3 Diarization: who spoke when", systemImage: "person.2.wave.2")
                Label("Qwen3-0.6B: meeting notes", systemImage: "text.badge.star")
            }
            .foregroundStyle(.secondary)
            if let status {
                HStack(spacing: 8) {
                    if running {
                        if let progress { ProgressView(value: progress).frame(width: 140) } else { ProgressView().controlSize(.small) }
                    }
                    Text(status).font(.callout)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).lineLimit(4) }
            HStack {
                Spacer()
                Button("Later") { dismiss() }.disabled(running)
                Button(running ? "Downloading..." : "Download") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func run() {
        running = true
        error = nil
        Task {
            do {
                try await engine.prepareModels { s, p in
                    status = s
                    progress = p
                }
                UserDefaults.standard.set(true, forKey: AppModel.modelsPreparedKey)
                running = false
                dismiss()
            } catch {
                self.error = error.localizedDescription
                running = false
            }
        }
    }
}
