import SwiftUI

struct StatusBadge: View {
    let status: MeetingStatus

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if status == .recording {
                    Image(systemName: status.icon)
                        .opacity(isPulsing ? 0.4 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: isPulsing
                        )
                        .onAppear { isPulsing = true }
                } else {
                    Image(systemName: status.icon)
                }
            }
            .imageScale(.small)

            Text(status.displayName)
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.15))
        .clipShape(Capsule())
    }
}

#Preview("All Statuses") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(MeetingStatus.allCases, id: \.self) { status in
            StatusBadge(status: status)
        }
    }
    .padding()
}

#Preview("Recording Pulse") {
    StatusBadge(status: .recording)
        .padding()
}
