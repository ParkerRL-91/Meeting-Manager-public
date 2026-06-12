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

    /// TASK-058: what happened involving the 1:1 counterpart since the
    /// last session with them. nil for multi-person meetings.
    let sinceLastMet: SinceLastMet?

    /// True when there is any prior context worth showing to the user.
    var hasContext: Bool { !relatedMeetings.isEmpty || !openActionItems.isEmpty || previousSession != nil || sinceLastMet != nil }
}

/// "Since you last met" diff for a 1:1 counterpart (TASK-058). Pure data;
/// built by SinceLastMetBuilder from rows the app already stores — no LLM.
struct SinceLastMet: Sendable {
    struct Item: Sendable, Identifiable {
        let id = UUID()
        let kind: String       // "commitment" | "decision" | "question" | "status" | "mention" | "actionItem"
        let text: String
        let meetingId: String?
        let meetingTitle: String?
    }
    let personName: String
    let lastMetDate: Date
    let items: [Item]
}

enum SinceLastMetBuilder {
    /// The single OTHER participant of a 1:1-shaped meeting (≤3 names,
    /// exactly one that isn't the local user). nil = not a 1:1.
    static func counterpart(participants: [String], selfName: String) -> String? {
        guard participants.count <= 3 else { return nil }
        let selfKey = VocativeMiningService.canonicalKey(for: selfName)
        let others = participants
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && VocativeMiningService.canonicalKey(for: $0) != selfKey }
        return others.count == 1 ? others.first : nil
    }

    /// Most recent past meeting (before `upcoming`) that includes the person.
    static func lastMeeting(with personKey: String, before date: Date,
                            excluding meetingId: String, in all: [Meeting]) -> Meeting? {
        all.filter { m in
            m.id != meetingId
            && m.effectiveDate < date
            && m.participantList.contains { VocativeMiningService.canonicalKey(for: $0) == personKey }
        }
        .max(by: { $0.effectiveDate < $1.effectiveDate })
    }

    /// Assemble the diff: dossier facts in the window, open action items
    /// assigned to them, and mentions in meetings they did NOT attend.
    @MainActor
    static func build(person: String, upcomingMeeting: Meeting,
                      allMeetings: [Meeting], database: AppDatabase,
                      transcriptRepo: TranscriptRepository,
                      actionItemRepo: ActionItemRepository) async -> SinceLastMet? {
        let personKey = VocativeMiningService.canonicalKey(for: person)
        guard !personKey.isEmpty,
              let last = lastMeeting(with: personKey, before: Date(),
                                     excluding: upcomingMeeting.id, in: allMeetings) else { return nil }
        let windowStart = last.effectiveDate
        let titles = Dictionary(uniqueKeysWithValues: allMeetings.map { ($0.id, $0.title) })
        var items: [SinceLastMet.Item] = []

        // Dossier facts extracted after the last session (their commitments,
        // decisions in rooms they were part of, owner-attributed items).
        let facts = (try? await EntityFactRepository(database: database)
            .facts(entityType: "person", entityKey: personKey, limit: 30)) ?? []
        for f in facts where f.extractedAt > windowStart && f.meetingId != last.id {
            items.append(.init(kind: f.kind, text: f.text,
                               meetingId: f.meetingId, meetingTitle: titles[f.meetingId]))
            if items.count >= 4 { break }
        }

        // Open action items assigned to them.
        let open = (try? await actionItemRepo.openItemsForParticipants([person])) ?? []
        for item in open.prefix(2) {
            items.append(.init(kind: "actionItem", text: item.title,
                               meetingId: item.meetingId, meetingTitle: titles[item.meetingId]))
        }

        // Mentions in meetings they did NOT attend (first name, window-bound).
        let firstName = person.components(separatedBy: " ").first ?? person
        if firstName.count > 2,
           let hits = try? await transcriptRepo.searchAllMeetings(query: firstName, limit: 6) {
            let attendedIds = Set(allMeetings.filter { m in
                m.participantList.contains { VocativeMiningService.canonicalKey(for: $0) == personKey }
            }.map(\.id))
            for hit in hits where !attendedIds.contains(hit.meetingId) {
                guard let m = allMeetings.first(where: { $0.id == hit.meetingId }),
                      m.effectiveDate > windowStart else { continue }
                items.append(.init(kind: "mention", text: hit.snippet,
                                   meetingId: hit.meetingId, meetingTitle: titles[hit.meetingId]))
                if items.count >= 7 { break }
            }
        }

        guard !items.isEmpty else { return nil }
        return SinceLastMet(personName: person, lastMetDate: windowStart, items: Array(items.prefix(6)))
    }
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
            // Series running thread (TASK-049) beats a single related-meeting
            // excerpt — it already synthesizes the whole series' state.
            let folderKey = MeetingFolder.normaliseTitle(meeting.title)
            if let thread = try? await SeriesThreadRepository(database: AppDatabase.shared).thread(folderKey: folderKey),
               !thread.content.isEmpty {
                return String(thread.content.prefix(1200))
            }
            guard let firstRelated = relatedMeetings.first else { return nil }
            let excerpt = firstRelated.summaryExcerpt
            return excerpt == "No summary available" ? nil : excerpt
        }()

        // 4. P5-T02: Detect prior sessions in the same series
        let previousSession = await previousSessionInfo(for: meeting)

        Logger.general.debug("PrepBrief for \(meeting.title): \(participants.count) participants, \(openItems.count) open items, \(relatedMeetings.count) related meetings")

        // TASK-058: 1:1 counterpart diff — what happened involving them
        // since the last session. Pure queries, no LLM.
        var sinceLastMet: SinceLastMet?
        if let counterpart = SinceLastMetBuilder.counterpart(
            participants: participants,
            selfName: ProcessInfo.processInfo.fullUserName
        ) {
            let all = (try? await MeetingRepository(database: AppDatabase.shared).allActiveMeetings()) ?? []
            sinceLastMet = await SinceLastMetBuilder.build(
                person: counterpart, upcomingMeeting: meeting,
                allMeetings: all, database: AppDatabase.shared,
                transcriptRepo: TranscriptRepository(database: AppDatabase.shared),
                actionItemRepo: actionItemRepo
            )
        }

        return MeetingPrepBrief(
            meetingId: meeting.id,
            participants: participants,
            openActionItems: openItems,
            relatedMeetings: relatedMeetings,
            lastSummaryExcerpt: lastExcerpt,
            meetLink: meeting.meetLink,
            previousSession: previousSession,
            sinceLastMet: sinceLastMet
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
