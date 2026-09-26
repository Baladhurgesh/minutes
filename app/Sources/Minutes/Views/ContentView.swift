import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: MeetingStore
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
        } detail: {
            Group {
                if let id = model.selection, store.meeting(id) != nil {
                    MeetingDetailView(meetingID: id).id(id)
                } else {
                    WelcomeView()
                }
            }
            .navigationTitle("")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import an audio or video file (⌘O)")
                RecordButton()
            }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.audio, .movie, .audiovisualContent],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.importFiles([url]) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted { DropOverlay() }
        }
        .sheet(isPresented: $model.showModelSetup) {
            ModelSetupView()
        }
        .confirmationDialog(
            "Delete “\(model.pendingDelete.flatMap { store.meeting($0)?.title } ?? "meeting")”?",
            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let id = model.pendingDelete { model.delete(id) }
                model.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("The recording, transcript and notes move to the Trash. You can restore them from there.")
        }
        .alert("Minutes", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: recorder.isRecording ? "stop.fill" : "circle.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(recorder.isRecording ? TimeFormat.clock(recorder.elapsed) : "Record")
                    .monospacedDigit()
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.red.gradient, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(recorder.isRecording ? "Stop recording and transcribe (⇧⌘R)" : "Record microphone and system audio (⇧⌘R)")
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 88, height: 88)
                        .shadow(color: .blue.opacity(0.25), radius: 12, y: 6)
                    Text("Welcome to Minutes").font(.system(size: 28, weight: .bold))
                    Text("Record or import a meeting to get a transcript with speakers and clear notes.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                FlowLayout(spacing: 16, lineSpacing: 16) {
                    ActionCard(title: "Record a meeting", subtitle: "Captures your microphone and call audio from Zoom, Meet or Teams.",
                               systemImage: "record.circle.fill", tint: .red, shortcut: "⇧⌘R") {
                        Task { await model.startRecording() }
                    }
                    ActionCard(title: "Import a file", subtitle: "Audio or video: MP3, M4A, WAV, MP4, MOV and more. Or drop it here.",
                               systemImage: "square.and.arrow.down.fill", tint: .accentColor, shortcut: "⌘O") {
                        model.showImporter = true
                    }
                }
                .frame(maxWidth: 600)
                Label("Everything runs on this Mac. Audio never leaves your computer.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: systemImage).font(.system(size: 26)).foregroundStyle(tint)
                    Spacer()
                    Text(shortcut).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(width: 270, height: 150, alignment: .topLeading)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? tint.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: hovering ? 1.5 : 1))
            .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 10 : 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
            Label("Drop to import", systemImage: "square.and.arrow.down")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}
