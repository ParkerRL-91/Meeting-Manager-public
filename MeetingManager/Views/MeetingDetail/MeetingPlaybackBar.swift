import SwiftUI

/// Transport for transcript-synced playback (TASK-077). Renders only when
/// the shared `AudioPlaybackService` has audio loaded for this meeting.
/// Play/pause, −15/+15, a draggable scrubber, elapsed/total, and a speed
/// menu (persisted). Docked at the bottom of the meeting detail view.
struct MeetingPlaybackBar: View {
    @Environment(AppState.self) private var appState
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var player: AudioPlaybackService { appState.audioPlayback }

    var body: some View {
        if player.isAvailable {
            HStack(spacing: 12) {
                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(.plain)
                .help("Back 15 seconds")

                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause" : "Play")

                Button { player.skip(by: 15) } label: {
                    Image(systemName: "goforward.15")
                }
                .buttonStyle(.plain)
                .help("Forward 15 seconds")

                Text(Self.timeLabel(scrubbing ? scrubValue : player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(width: 46, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubValue : player.currentTime },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(player.duration, 0.1),
                    onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { player.seek(to: scrubValue) }
                    }
                )
                .controlSize(.small)

                Text(Self.timeLabel(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.appTextTertiary)
                    .frame(width: 46, alignment: .leading)

                Menu {
                    ForEach(AudioPlaybackService.availableRates, id: \.self) { r in
                        Button {
                            player.setRate(r)
                        } label: {
                            if player.rate == r { Label(Self.rateLabel(r), systemImage: "checkmark") }
                            else { Text(Self.rateLabel(r)) }
                        }
                    }
                } label: {
                    Text(Self.rateLabel(player.rate))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .frame(width: 34)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Playback speed")
            }
            .font(.body)
            .foregroundStyle(Color.appTextSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.appBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.appSeparator).frame(height: 1)
            }
        }
    }

    static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }
}
