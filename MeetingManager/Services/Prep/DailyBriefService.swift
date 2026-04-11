import Foundation
import os

// MARK: - Category

/// How well-prepared a meeting slot is, based on available prior context.
enum MeetingPrepCategory: String, Sendable {
    /// Has related past meetings AND open action items — needs attention.
    case carryOver
    /// Has related past meetings but no open items — good for context.
    case followUp
    /// No prior context — fresh conversation.
    case new
}

// MARK: - DailyBriefEntry

/// One meeting's worth of data for the daily brief.
struct DailyBriefEntry: Sendable {
    let meeting: Meeting
    let prepBrief: MeetingPrepBrief
    let category: MeetingPrepCategory
}

// MARK: - DailyBrief

/// Aggregated briefing for a single calendar day.
struct DailyBrief: Sendable {
    let date: Date
    let meetings: [DailyBriefEntry]
    /// Total open action items across all meetings.
    let totalOpenItems: Int
    /// Number of meetings with carry-over context (carryOver count).
    let meetingsNeedingPrep: Int
}

// MARK: - DailyBriefService

/// Builds a `DailyBrief` for a given date by combining `MeetingRepository`
/// and `MeetingPrepService` data.
final class DailyBriefService {
    private let meetingRepository: MeetingRepository
    private let prepService: MeetingPrepService

    init(
        meetingRepository: MeetingRepository = MeetingRepository(database: .shared),
        prepService: MeetingPrepService = MeetingPrepService()
    ) {
        self.meetingRepository = meetingRepository
        self.prepService = prepService
    }

    /// Fetch all meetings for `date`, build prep briefs for each, categorize them,
    /// and return an assembled `DailyBrief`.
    func buildBrief(for date: Date) async throws -> DailyBrief {
        // 1. Fetch meetings for the date
        let meetings = try await meetingRepository.allMeetingsForDate(date)
        Logger.general.info("DailyBriefService: found \(meetings.count) meetings for \(date)")

        // 2. Build prep briefs in batch
        let briefs = try await prepService.prepBriefs(for: meetings)

        // 3. Categorize each meeting and assemble entries
        var entries: [DailyBriefEntry] = []
        var totalOpenItems = 0
        var carryOverCount = 0

        for meeting in meetings {
            guard let brief = briefs[meeting.id] else { continue }

            let category: MeetingPrepCategory
            if !brief.relatedMeetings.isEmpty && !brief.openActionItems.isEmpty {
                category = .carryOver
                carryOverCount += 1
            } else if !brief.relatedMeetings.isEmpty {
                category = .followUp
            } else {
                category = .new
            }

            totalOpenItems += brief.openActionItems.count
            entries.append(DailyBriefEntry(meeting: meeting, prepBrief: brief, category: category))
        }

        // Sort by scheduled start date
        entries.sort {
            let a = $0.meeting.scheduledStartDate ?? $0.meeting.startDate ?? .distantFuture
            let b = $1.meeting.scheduledStartDate ?? $1.meeting.startDate ?? .distantFuture
            return a < b
        }

        return DailyBrief(
            date: date,
            meetings: entries,
            totalOpenItems: totalOpenItems,
            meetingsNeedingPrep: carryOverCount
        )
    }
}
