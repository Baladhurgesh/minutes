import SwiftUI

/// Bottom playback bar: skip, play/pause, speaker-colored scrubber, speed.
struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer
    let turns: [Turn]

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    .help("Back 15 seconds")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Brand.gradient, in: Circle())
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    .help("Forward 15 seconds")
            }
            .buttonStyle(.plain)
            .font(.system(size: 15))

            Text(TimeFormat.clock(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)
            SpeakerScrubber(player: player, turns: turns)
            Text(TimeFormat.clock(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .leading)

            Menu {
                ForEach(AudioPlayer.rates, id: \.self) { r in
                    Button { player.rate = r } label: {
                        if r == player.rate { Label(Self.rateLabel(r), systemImage: "checkmark") } else { Text(Self.rateLabel(r)) }
                    }
                }
            } label: {
                Text(Self.rateLabel(player.rate)).font(.caption.monospacedDigit().weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    static func rateLabel(_ r: Float) -> String {
        r == r.rounded() ? "\(Int(r))x" : String(format: "%.2gx", r)
    }
}

/// Timeline where each speaker turn is drawn in that speaker's color; click or drag to seek.
struct SpeakerScrubber: View {
    @ObservedObject var player: AudioPlayer
    let turns: [Turn]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(player.duration, 0.1)
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                        Rectangle()
                            .fill(SpeakerColors.color(turn.speaker).opacity(0.75))
                            .frame(width: max(1.5, width * (turn.end - turn.start) / duration))
                            .offset(x: width * turn.start / duration)
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                    .frame(width: 13, height: 13)
                    .offset(x: min(max(0, width * player.currentTime / duration - 6.5), width - 13))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                player.seek(min(max(0, v.location.x / width), 1) * duration, play: false)
            })
        }
        .frame(height: 20)
    }
}
