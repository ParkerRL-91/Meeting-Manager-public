import SwiftUI

/// Compact horizontal audio-level meter used in the recording control bar.
struct AudioLevelIndicator: View {
    let label: String
    let level: Float
    var color: Color = .appAccent

    private let maxWidth: CGFloat = 80
    private let barHeight: CGFloat = 6

    /// Clamp the fill to [0, 1] of the track. `level` is RMS in [0, 1]; we
    /// amplify for visibility but NEVER let the fill exceed the track width.
    private var fillFraction: CGFloat {
        let amplified = CGFloat(level) * 20
        return min(max(amplified, 0), 1)
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(Color.appSurfaceSecondary)
                    .frame(width: maxWidth, height: barHeight)

                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(color)
                    .frame(width: fillFraction * maxWidth, height: barHeight)
                    .animation(.linear(duration: 0.1), value: level)
            }
            // Hard-pin the whole meter to the track width so no surrounding
            // layout (e.g. the Ask-anything bar's internal Spacer) can stretch it.
            .frame(width: maxWidth)

            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.appTextSecondary)
        }
        .frame(width: maxWidth)
        .fixedSize()
    }
}

// MARK: - Preview

// #Preview {
//     HStack(spacing: 16) {
//         AudioLevelIndicator(label: "\u{1F3A4}", level: 0.6, color: .appAccent)
//         AudioLevelIndicator(label: "\u{1F50A}", level: 0.85, color: .appSuccess)
//     }
//     .padding()
//     .background(Color.appBackground)
// }
