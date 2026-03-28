import SwiftUI

/// Compact horizontal audio-level meter used in the recording control bar.
struct AudioLevelIndicator: View {
    let label: String
    let level: Float
    var color: Color = .appAccent

    private let maxWidth: CGFloat = 80
    private let barHeight: CGFloat = 6

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(Color.appSurfaceSecondary)
                    .frame(width: maxWidth, height: barHeight)

                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(color)
                    .frame(width: CGFloat(min(max(level, 0), 1)) * maxWidth, height: barHeight)
                    .animation(.linear(duration: 0.1), value: level)
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.appTextSecondary)
        }
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
