import AVFoundation
import Foundation

@MainActor
final class AudioPlayer: ObservableObject {
    static let rates: [Float] = [1, 1.25, 1.5, 2]

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1 {
        didSet { player?.rate = rate }
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.enableRate = true
        player?.rate = rate
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
        tick()
    }

    func seek(_ time: Double, play shouldPlay: Bool = true) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
        if shouldPlay && !isPlaying { play() }
    }

    func skip(_ delta: Double) { seek(currentTime + delta, play: isPlaying) }

    func stop() {
        pause()
        player?.stop()
        player = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying && isPlaying {
            isPlaying = false
            timer?.invalidate()
            timer = nil
        }
    }
}
