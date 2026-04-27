import Foundation
import os

// MARK: - Prep Brief Model

/// Aggregated preparation context for an upcoming meeting.
/// Combines related past meetings, open action items, and the latest summary
/// excerpt into a single struct for display on HomeView prep cards.
struct MeetingPrepBrief: Sendable {
    let meetingId: String
    let participants: [String]
    let openActionItems: [ActionItem]
    let relatedMeetings: [RelevantMeeting]
    let lastSummaryExcerpt: String?
    let meetLink: String?
    /// P5-T02: Most recent prior meeting in the same series, when detectable.
    /// Used to render the "Last time:" line on prep cards.
    let previousSession: PreviousSessionInfo?

    /// True when there is any prior context worth showing to the user.
    var hasContext: Bool { !relatedMeetings.isEmpty || !openActionItems.isEmpty || previousSession != nil }
}

/// Lightweight snapshot of a prior session in the same series, suitable for UI.
struct PreviousSessionInfo: Sendable {
    let meetingId: String
    let title: String
    let date: Date
    let summaryExcerpt: String?
}

// MARK: - Meeting Prep Service

/// Produces a `MeetingPrepBrief` for any meeting by aggregating data from
/// `RelevantMeetingService`, `ActionItemRepository`, and `SummaryRepository`.
/// This is the foundation service for the "Always Prepared" feature set —
/// used by prep cards, "Up Next" banners, smart notifications, and daily briefs.
final class MeetingPrepService {
    private let database: AppDatabase
    private let actionItemRepo: ActionItemRepository
    private let summaryRepo: SummaryRepository

    init(database: AppDatabase = .shared) {
        self.database = database
        self.actionItemRepo = ActionItemRepository(database: database)
        self.summaryRepo = SummaryRepository(database: database)
    }

    /// Build a prep brief for the given meeting.
    ///
    /// Gathers: related past meetings (from cached contextJSON), open action
    /// items for this meeting's participants, and the latest summary excerpt
    /// from the most recent related meeting.
    func prepBrief(for meeting: Meeting) async throws -> MeetingPrepBrief {
        let participants = meeting.participantList

        // 1. Related past meetings (from cached contextJSON)
        let relatedMeetings = RelevantMeetingService.parseContext(from: meeting.contextJSON)

        // 2. Open action items for these participants
        let openItems = try await actionItemRepo.openItemsForParticipants(participants)

        // 3. Latest summary excerpt from the most recent related meeting
        let lastExcerpt: String? = await {
            guard let firstRelated = relatedMeetings.first else { return nil }
            let excerpt = firstRelated.summaryExcerpt
            return excerpt == "No summary available" ? nil : excerpt
        }()

        // 4. P5-T02: Detect prior sessions in the same series
        let previousSession = await previousSessionInfo(for: meeting)

        Logger.general.debug("PrepBrief for \(meeting.title): \(participants.count) participants, \(openItems.count) open items, \(relatedMeetings.count) related meetings")

        return MeetingPrepBrief(
            meetingId: meeting.id,
            participants: participants,
            openActionItems: openItems,
            relatedMeetings: relatedMeetings,
            lastSummaryExcerpt: lastExcerpt,
            meetLink: meeting.meetLink,
            previousSession: previousSession
        )
    }

    /// Build prep briefs for multiple meetings in a batch.
    /// More efficient than calling `prepBrief(for:)` individually when loading
    /// all of today's meetings on HomeView.
    func prepBriefs(for meetings: [Meeting]) async throws -> [String: MeetingPrepBrief] {
        var result: [String: MeetingPrepBrief] = [:]
        for meeting in meetings {
            result[meeting.id] = try await prepBrief(for: meeting)
        }
        return result
    }

    // MARK: - P5-T02 Series Awareness

    /// Looks up the most recent prior session in the same series. Returns nil
    /// when no series is detected or no candidates exist in the database.
    private func previousSessionInfo(for meeting: Meeting) async -> PreviousSessionInfo? {
        let candidates: [Meeting]
        do {
            candidates = try await MeetingRepository(database: database).pastMeetings(limit: 200)
        } catch {
            return nil
        }
        let series = await MainActor.run {
            MeetingSeriesService.shared.detectSeries(for: meeting, in: candidates)
        }
        guard let prev = series.first else { return nil }
        let excerpt = (try? await summaryRepo.latestSummary(meetingId: prev.id))?.summaryText
        let trimmed = excerpt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 0, omittingEmptySubsequences: true)
            .first
            .map(String.init)
        let date = prev.scheduledStartDate ?? prev.startDate ?? prev.createdAt
        return PreviousSessionInfo(
            meetingId: prev.id,
            title: prev.title,
            date: date,
            summaryExcerpt: trimmed
        )
    }
}
