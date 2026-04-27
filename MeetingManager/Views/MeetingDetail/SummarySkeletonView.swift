import SwiftUI

/// Unified placeholder shown while a meeting is in any pre-summary processing
/// state (transcribing, summarizing). Replaces the previous stage-by-stage
/// progress UI with a single calm shimmer.
///
/// Design intent (P1-T05): hide pipeline mechanics from the user. They don't
/// need to know whether we're transcribing vs. summarizing — they just need
/// to know their notes are being prepared.
struct SummarySkeletonView: View {
    @State private var phase: CGFloat = -1

    /// Relative widths for the four shimmer rows (fraction of available width).
    private let rowWidths: [CGFloat] = [0.92, 0.78, 0.85, 0.55]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rowWidths.indices, id: \.self) { index in
                shimmerBar(widthFraction: rowWidths[index])
            }

            Text("Preparing your notes…")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appBackground)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = 2
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing your notes")
    }

    @ViewBuilder
    private func shimmerBar(widthFraction: CGFloat) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width * widthFraction
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.appSurface)
                    .frame(width: width, height: 14)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.appAccent.opacity(0.18),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.4, height: 14)
                    .offset(x: phase * width)
                    .mask(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .frame(width: width, height: 14)
                    )
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Preview

// #Preview {
//     SummarySkeletonView()
//         .frame(width: 600, height: 400)
//         .background(Color.appBackground)
// }
