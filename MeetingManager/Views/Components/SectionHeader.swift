import SwiftUI

// MARK: - Section Header (shared component)

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.appTextTertiary)
            .textCase(.uppercase)
            .tracking(0.8)
    }
}
