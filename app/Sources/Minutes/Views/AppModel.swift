import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AudioExporter {
    /// AAC in an M4A container: roughly a tenth of the size of the 16 kHz WAV.
    static func exportM4A(from source: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MinutesError.audio("M4A export is not available")
        }
        if #available(macOS 15, *) {
            try await session.export(to: dest, as: .m4a)
        } else {
            session.outputURL = dest
            session.outputFileType = .m4a
            await session.export()
            if let error = session.error { throw error }
        }
    }
}

/// App-level state and actions shared by the window, menus and settings.
@MainActor
final class AppModel: ObservableObject {
    static let captureSystemAudioKey = "captureSystemAudio"
    static let inputDeviceKey = "inputDeviceUID"
    static let modelsPreparedKey = "modelsPrepared"

    /// Listed explicitly so MP3 and friends are selectable even when their UTI does not resolve to `.audio`.
    static let uploadTypes: [UTType] = [.mp3, .mpeg4Audio, .wav, .aiff, .audio, .movie, .mpeg4Movie, .quickTimeMovie]
        + ["m4a", "aac", "flac", "caf", "ogg", "opus"].compactMap { UTType(filenameExtension: $0) }
    /// Recognised as media by macOS, but AVFoundation cannot decode them.
    static let unsupportedExtensions: Set<String> = ["webm", "mkv", "wma", "wmv", "avi"]

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

    /// Shows the home (welcome) screen by clearing the meeting selection.
    func goHome() {
        selection = nil
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
        let media = urls.filter(Self.isMedia)
        let skipped = urls.filter { !Self.isMedia($0) }.map(\.lastPathComponent)
        if !skipped.isEmpty {
            alertMessage = "Can't upload \(skipped.joined(separator: ", ")). "
                + "Minutes accepts MP3, M4A, WAV, AAC, FLAC, OGG and MP4 or MOV videos."
        }
        for url in media {
            Task {
                if let id = await pipeline.importFile(url) { selection = id }
            }
        }
    }

    static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !unsupportedExtensions.contains(ext), let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
            || uploadTypes.contains(type)
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
        guard let meeting = store.meeting(id),
              let url = savePanel(named: meeting.title, ext: "md", type: .init(filenameExtension: "md") ?? .plainText)
        else { return }
        do {
            try store.exportMarkdown(id).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    enum RecordingFormat: String, CaseIterable {
        case m4a, wav

        var label: String { self == .m4a ? "Recording (M4A, smaller)" : "Recording (WAV, original)" }
    }

    func hasRecording(_ id: UUID) -> Bool {
        guard let m = store.meeting(id), m.status != .recording, m.status != .importing else { return false }
        return FileManager.default.fileExists(atPath: store.audioURL(id).path)
    }

    /// Saves the meeting audio where the user picks, as the original WAV or a compressed M4A.
    func downloadRecording(_ id: UUID, format: RecordingFormat) {
        guard let meeting = store.meeting(id), hasRecording(id),
              let dest = savePanel(named: meeting.title, ext: format.rawValue, type: format == .m4a ? .mpeg4Audio : .wav)
        else { return }
        let source = store.audioURL(id)
        Task {
            do {
                try? FileManager.default.removeItem(at: dest)
                switch format {
                case .wav:
                    try FileManager.default.copyItem(at: source, to: dest)
                case .m4a:
                    try await AudioExporter.exportM4A(from: source, to: dest)
                }
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                alertMessage = "Could not save the recording: \(error.localizedDescription)"
            }
        }
    }

    private func savePanel(named title: String, ext: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "." + ext
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Delete

    /// Set to ask for confirmation before deleting (the dialog lives in ContentView).
    @Published var pendingDelete: UUID?

    func requestDelete(_ id: UUID) {
        guard store.meeting(id)?.status != .recording else { return }
        pendingDelete = id
    }
}
