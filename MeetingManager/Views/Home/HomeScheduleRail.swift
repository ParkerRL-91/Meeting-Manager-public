import SwiftUI

/// Today's schedule as a categorized time-rail: a time column, a category dot
/// (carryOver / followUp / new), and an expandable prep card per meeting.
/// Ported from the former `DailyBriefView` timeline; adopts Home's 24px
/// horizontal padding. Fed by `DailyBriefService.buildBrief`.
struct HomeScheduleRail: View {
    let brief: DailyBrief
    let now: Date
    @Binding var expandedCardIds: Set<String>

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Vertical time rail line
            Rectangle()
                .fill(Color.appSeparator)
                .frame(width: 1)
                .padding(.leading, 72)
                .padding(.top, 8)

            VStack(spacing: 16) {
                ForEach(brief.meetings, id: \.meeting.id) { entry in
                    timelineRow(entry: entry)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func timelineRow(entry: DailyBriefEntry) -> some View {
        let isExpanded = Binding<Bool>(
            get: { expandedCardIds.contains(entry.meeting.id) },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if newValue { expandedCardIds.insert(entry.meeting.id) }
                    else { expandedCardIds.remove(entry.meeting.id) }
                }
            }
        )
        let dotColor = Self.categoryColor(for: entry.category)

        return HStack(alignment: .top, spacing: 0) {
            // Time column — 56px, right-aligned, monospaced
            VStack(alignment: .trailing, spacing: 2) {
                if let start = entry.meeting.scheduledStartDate ?? entry.meeting.startDate {
                    Text(start, format: .dateTime.hour().minute())
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.appTextSecondary)
                }
                if let end = entry.meeting.scheduledEndDate {
                    Text(end, format: .dateTime.hour().minute())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.appTextMuted)
                }
            }
            .frame(width: 56, alignment: .trailing)
            .padding(.top, 2)

            // Dot — 17px wide, centered on the rail
            ZStack {
                Circle()
                    .fill(Color.appBackground)
                    .frame(width: 15, height: 15)
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
            }
            .frame(width: 17)
            .padding(.horizontal, 4)
            .padding(.top, 4)

            MeetingPrepCardView(
                meeting: entry.meeting,
                prepBrief: entry.prepBrief,
                now: now,
                isExpanded: isExpanded
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(dotColor)
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
    }

    static func categoryColor(for category: MeetingPrepCategory) -> Color {
        switch category {
        case .carryOver: return Color.appRecording
        case .followUp:  return Color.appWarning
        case .new:       return Color.appAccentMid
        }
    }
}
