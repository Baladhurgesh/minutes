import AppKit
import Foundation
import SwiftUI

/// App-level state and actions shared by the window, menus and settings.
@MainActor
final class AppModel: ObservableObject {
    static let captureSystemAudioKey = "captureSystemAudio"
    static let inputDeviceKey = "inputDeviceUID"
    static let modelsPreparedKey = "modelsPrepared"

    let store = MeetingStore()
    let engine = EngineManager()
    let recorder = Recorder()
    let pipeline: MeetingPipeline

    @Published var selection: UUID?
    @Published var alertMessage: String?
    @Published var showImporter = false
    @Published var showModelSetup = false
    @Published private(set) var recordingMeeting: UUID?

    private var launched = false

    init() {
        pipeline = MeetingPipeline(store: store, engine: engine)
        UserDefaults.standard.register(defaults: [Self.captureSystemAudioKey: true])
    }

    func launch() async {
        guard !launched else { return }
        launched = true
        selection = store.meetings.first?.id
        #if DEBUG
        if DebugSnapshot.isActive { return }
        #endif
        if !UserDefaults.standard.bool(forKey: Self.modelsPreparedKey) { showModelSetup = true }
        pipeline.resumePending()
        _ = try? await engine.ensureReady()
    }

    func toggleRecording() async {
        if recorder.isRecording { await stopRecording() } else { await startRecording() }
    }

    func startRecording() async {
        guard !recorder.isRecording else { return }
        let defaults = UserDefaults.standard
        do {
            let meeting = try store.create(source: "recording", status: .recording)
            recordingMeeting = meeting.id
            selection = meeting.id
            let uid = defaults.string(forKey: Self.inputDeviceKey).flatMap { $0.isEmpty ? nil : $0 }
            do {
                try await recorder.start(directory: store.directory(for: meeting.id),
                                         captureSystemAudio: defaults.bool(forKey: Self.captureSystemAudioKey),
                                         inputDeviceUID: uid)
            } catch {
                store.delete(meeting.id)
                recordingMeeting = nil
                selection = store.meetings.first?.id
                throw error
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard let id = recordingMeeting else { return }
        recordingMeeting = nil
        do {
            let result = try await recorder.stop()
            pipeline.finishRecording(id, result: result)
        } catch {
            store.update(id) { $0.status = .failed; $0.error = error.localizedDescription }
        }
    }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            Task {
                if let id = await pipeline.importFile(url) { selection = id }
            }
        }
    }

    func delete(_ id: UUID) {
        pipeline.cancel(id)
        store.delete(id)
        if selection == id { selection = store.meetings.first?.id }
    }

    func retry(_ id: UUID) {
        pipeline.enqueue(id)
    }

    func revealInFinder(_ id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: id)])
    }

    func exportMarkdown(_ id: UUID) {
        guard let meeting = store.meeting(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportMarkdown(id).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
