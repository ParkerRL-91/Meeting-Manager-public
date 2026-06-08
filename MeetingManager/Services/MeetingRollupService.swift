import Foundation

/// Read-only cross-meeting rollups for a person or company profile. Cheap by
/// design: bounded reads, no LLM, no network (see ADR-014). Used by the
/// People/Companies detail panes.
struct MeetingRollupService {
    private let actionItemRepo: ActionItemRepository
    private let summaryRepo: SummaryRepository

    init(
        actionItemRepo: ActionItemRepository = ActionItemRepository(),
        summaryRepo: SummaryRepository = SummaryRepository(database: .shared)
    ) {
        self.actionItemRepo = actionItemRepo
        self.summaryRepo = summaryRepo
    }

    /// Open action items assigned to any of these participant names. One query
    /// with fuzzy assignee matching — best for a single person's profile.
    func openActionItems(forParticipants participants: [String]) async -> [ActionItem] {
        (try? await actionItemRepo.openItemsForParticipants(participants)) ?? []
    }

    /// Open action items grouped by meeting across the given meetings (most
    /// recent first, capped). Action items aren't tagged by org, so a company
    /// profile walks its meetings rather than matching assignees.
    func openActionItems(
        forMeetings meetings: [Meeting],
        cap: Int = 40
    ) async -> [(meeting: Meeting, items: [ActionItem])] {
        let recent = meetings.sorted { $0.effectiveDate > $1.effectiveDate }.prefix(cap)
        var out: [(meeting: Meeting, items: [ActionItem])] = []
        for meeting in recent {
            let open = ((try? await actionItemRepo.itemsForMeeting(meeting.id)) ?? [])
                .filter { !$0.isCompleted }
            if !open.isEmpty { out.append((meeting, open)) }
        }
        return out
    }

    /// The most recent meetings (from the given set) that have a saved summary,
    /// for snippet display. Bounded to `limit` reads.
    func recentSummaries(
        forMeetings meetings: [Meeting],
        limit: Int = 5
    ) async -> [(meeting: Meeting, summary: MeetingSummary)] {
        let recent = meetings.sorted { $0.effectiveDate > $1.effectiveDate }
        var out: [(meeting: Meeting, summary: MeetingSummary)] = []
        for meeting in recent {
            if out.count >= limit { break }
            if let summary = try? await summaryRepo.latestSummary(meetingId: meeting.id),
               !summary.summaryText.isEmpty {
                out.append((meeting, summary))
            }
        }
        return out
    }
}
