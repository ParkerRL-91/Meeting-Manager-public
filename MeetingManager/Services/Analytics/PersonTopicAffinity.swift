import Foundation

/// "Who have I already discussed this with?" (TASK-060). Pure ranking of
/// people by their meetings' semantic relevance to a query, decayed by
/// recency. No tables, no LLM — a view over embedding hits the search
/// sheet already produces.
enum PersonTopicAffinity {

    struct Ranked: Equatable {
        let name: String
        let score: Double
        let meetingCount: Int
        let lastDiscussed: Date
    }

    /// Hits below this cosine score are noise, not "discussed this".
    static let minScore: Float = 0.4
    /// Recency half-life-ish constant: a 90-day-old discussion counts ~1/e.
    static let recencyDays = 90.0

    static func rank(hits: [(meetingId: String, score: Float)],
                     meetings: [Meeting],
                     excludingSelf selfName: String,
                     now: Date = Date(),
                     limit: Int = 4) -> [Ranked] {
        // Best score per meeting — five chunks from one meeting are one
        // discussion, not five.
        var bestByMeeting: [String: Float] = [:]
        for hit in hits where hit.score >= minScore {
            bestByMeeting[hit.meetingId] = max(bestByMeeting[hit.meetingId] ?? 0, hit.score)
        }
        guard !bestByMeeting.isEmpty else { return [] }

        let selfKey = VocativeMiningService.canonicalKey(for: selfName)
        let byId = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })

        struct Accumulator { var score = 0.0; var count = 0; var last = Date.distantPast; var name = "" }
        var acc: [String: Accumulator] = [:]

        for (meetingId, score) in bestByMeeting {
            guard let meeting = byId[meetingId] else { continue }
            let ageDays = max(0, now.timeIntervalSince(meeting.effectiveDate) / 86_400)
            let weight = Double(score) * exp(-ageDays / recencyDays)
            for raw in meeting.participantList {
                let name = raw.trimmingCharacters(in: .whitespaces)
                let key = VocativeMiningService.canonicalKey(for: name)
                guard !key.isEmpty, key != selfKey else { continue }
                var a = acc[key] ?? Accumulator()
                a.score += weight
                a.count += 1
                if meeting.effectiveDate > a.last {
                    a.last = meeting.effectiveDate
                    a.name = name
                }
                acc[key] = a
            }
        }

        let ranked: [Ranked] = acc.values.map { a in
            Ranked(name: a.name, score: a.score, meetingCount: a.count, lastDiscussed: a.last)
        }
        let sorted = ranked.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.name < rhs.name : lhs.score > rhs.score
        }
        return Array(sorted.prefix(limit))
    }
}
