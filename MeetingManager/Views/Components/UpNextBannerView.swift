import SwiftUI

/// Horizontal "Up Next" banner shown in MeetingDetailView after a recording stops.
/// Displays the next upcoming meeting's time, title, participant count, open items
/// count, a "Prep" navigation button, and a dismiss "X" button.
struct UpNextBannerView: View {
    let meeting: Meeting
    let prepBrief: MeetingPrepBrief?
    let onPrep: () -> Void
    let onDismiss: () -> Void

    @Environment(AppState.self) private var appState

    // MARK: - Computed

    private var scheduledTime: Date? {
        meeting.scheduledStartDate ?? meeting.startDate
    }

    private var participantCount: Int {
        meeting.participantList.count
    }

    private var openItemsCount: Int {
        prepBrief?.openActionItems.count ?? 0
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            // Up Next label
            VStack(alignment: .leading, spacing: 1) {
                Text("UP NEXT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .tracking(0.8)

                if let time = scheduledTime {
                    Text(time, format: .dateTime.hour().minute())
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.appTextPrimary)
                }
            }
            .frame(width: 52, alignment: .leading)

            // Left accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.appAccent)
                .frame(width: 3, height: 32)

            // Title + badges
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    // Participant count badge
                    if participantCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "person.2")
                                .font(.caption2)
                            Text("\(participantCount)")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appSurfaceSecondary)
                        .clipShape(Capsule())
                    }

                    // Open items badge (only if any)
                    if openItemsCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle")
                                .font(.caption2)
                            Text("\(openItemsCount) open")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(Color.appWarning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appWarning.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            // Prep button
            Button("Prep") {
                onPrep()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .controlSize(.small)

            // Dismiss button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    onDismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.appAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
        )
    }
}
