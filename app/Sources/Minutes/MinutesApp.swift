import SwiftUI

@main
struct MinutesApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Minutes") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.engine)
                .environmentObject(model.pipeline)
                .environmentObject(model.recorder)
                .frame(minWidth: 700, minHeight: 480)
                .task {
                    #if DEBUG
                    DebugSnapshot.runIfRequested(model: model)
                    #endif
                    await model.launch()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.recorder.isRecording ? "Stop Recording" : "New Recording") {
                    Task { await model.toggleRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Upload Recording (MP3, M4A, WAV, Video)...") { model.showImporter = true }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.engine)
        }
    }
}
