import SwiftUI

// MARK: - Initials Avatar (shared component)

struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 28
    var index: Int = 0

    private static let avatarColors: [Color] = [
        Color.appAccent,
        .purple,
        .orange,
        .green,
        .pink,
        .teal
    ]

    private var initials: String {
        let parts = name.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1)) + String(parts[1].prefix(1))
        }
        return String(name.prefix(2)).uppercased()
    }

    private var backgroundColor: Color {
        InitialsAvatar.avatarColors[abs(name.hashValue) % InitialsAvatar.avatarColors.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.opacity(0.85))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.appBackground, lineWidth: 1.5))
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
