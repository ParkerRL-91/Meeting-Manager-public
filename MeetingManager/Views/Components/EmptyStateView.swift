import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    /// Optional call-to-action button. When supplied, renders a prominent button
    /// under the subtitle so empty lists give the user an obvious next step.
    var ctaLabel: String? = nil
    var ctaAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title2)
                .fontWeight(.medium)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let ctaLabel, let ctaAction {
                Button(action: ctaAction) {
                    Text(ctaLabel)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: 300)
    }
}

// #Preview("No Meetings") {
//     EmptyStateView(
//         icon: "calendar.badge.plus",
//         title: "No Meetings",
//         subtitle: "Your upcoming meetings will appear here once they are scheduled."
//     )
//     .frame(width: 400, height: 300)
// }

// #Preview("No Results") {
//     EmptyStateView(
//         icon: "magnifyingglass",
//         title: "No Results",
//         subtitle: "Try adjusting your search terms or filters."
//     )
//     .frame(width: 400, height: 300)
// }
