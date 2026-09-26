import Foundation

/// Prints "label NN%" to stderr only when the whole percentage changes.
final class ProgressPrinter: @unchecked Sendable {
    private let label: String
    private let lock = NSLock()
    private var last = -1

    init(label: String) { self.label = label }

    func report(_ fraction: Double) {
        let pct = Int((fraction * 100).rounded(.down))
        let changed: Bool = lock.withLock {
            guard pct != last else { return false }
            last = pct
            return true
        }
        if changed { fputs("\r  \(label) \(pct)%\(pct >= 100 ? "\n" : "")", stderr) }
    }
}
