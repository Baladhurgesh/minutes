#if DEBUG
import AppKit

/// Debug-only: `MINUTES_SNAPSHOT_DIR=/tmp/shots MINUTES_SNAPSHOT_SIZES=1280x800,760x520` makes the app resize its
/// main window to each size, write `<w>x<h>.png` of the window contents, then quit. Used to review layouts headlessly.
enum DebugSnapshot {
    /// Snapshot runs never start the engine or process queued meetings.
    static var isActive: Bool { ProcessInfo.processInfo.environment["MINUTES_SNAPSHOT_DIR"] != nil }

    /// `MINUTES_SNAPSHOT_SELECT=none` captures the welcome screen; `=<meeting UUID>` selects that meeting.
    @MainActor
    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MINUTES_SNAPSHOT_DIR"] else { return }
        if let select = env["MINUTES_SNAPSHOT_SELECT"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                model.selection = select == "none" ? nil : UUID(uuidString: select)
            }
        }
        let sizes = (env["MINUTES_SNAPSHOT_SIZES"] ?? "1280x800").split(separator: ",").compactMap { s -> CGSize? in
            let p = s.split(separator: "x").compactMap { Double($0) }
            return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for size in sizes {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { break }
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let name = "\(Int(size.width))x\(Int(size.height)).png"
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                // Own-window capture needs no Screen Recording permission and includes vibrancy/materials.
                if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                       [.boundsIgnoreFraming, .bestResolution]) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                } else if let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
