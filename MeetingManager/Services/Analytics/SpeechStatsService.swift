import Foundation
import GRDB

// MARK: - SpeechStats (TASK-059, migration v54)

/// Per-meeting speaking metrics for the USER only — talk share,
/// interruptions, filler density, question rate, longest monologue.
/// Pure math over diarized transcripts; no LLM, nothing leaves the
/// machine. Surfaced opt-in and framed neutrally (plan risk: tone).
struct SpeechStats: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "speechStats"

    var meetingId: String
    var talkShare: Double          // 0–1, user speech / all speech
    var interruptions: Int         // user starts inside someone else's segment
    var fillerPer100: Double       // filler words per 100 user words
    var questionRate: Double       // 0–1, ?-sentences / user sentences
    var longestMonologueSec: Double
    var userWordCount: Int
    var computedAt: Date

    var id: String { meetingId }
}

final class SpeechStatsRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func find(meetingId: String) async throws -> SpeechStats? {
        try await database.writer.read { db in try SpeechStats.fetchOne(db, key: meetingId) }
    }

    func save(_ stats: SpeechStats) async throws {
        try await database.writer.write { db in try stats.save(db) }
    }

    func stats(meetingIds: [String]) async throws -> [SpeechStats] {
        guard !meetingIds.isEmpty else { return [] }
        return try await database.writer.read { db in
            try SpeechStats.filter(keys: meetingIds).fetchAll(db)
        }
    }

    /// Meetings that have transcripts but no stats row — the backfill list.
    func unprocessedMeetingIds() async throws -> [String] {
        try await database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT meetingId FROM transcript
                WHERE meetingId NOT IN (SELECT meetingId FROM speechStats)
                """)
        }
    }
}

// MARK: - Builder (pure)

enum SpeechStatsBuilder {

    static let fillerPattern = "\\b(um+|uh+|erm|hmm|like|you know|sort of|kind of|i mean|basically|literally|actually)\\b"
    /// Gaps shorter than this merge into one monologue run.
    static let monologueGapSec = 2.0

    /// Is this segment the user's? The mic channel is labeled "mic" until
    /// attribution renames it to the user's display name.
    static func isUserLabel(_ label: String?, selfKey: String) -> Bool {
        guard let label, !label.isEmpty else { return false }
        if label.lowercased() == "mic" { return true }
        return VocativeMiningService.canonicalKey(for: label) == selfKey
    }

    static func build(meetingId: String,
                      transcripts: [Transcript],
                      selfName: String,
                      now: Date = Date()) -> SpeechStats? {
        let selfKey = VocativeMiningService.canonicalKey(for: selfName)
        let spoken = transcripts.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !spoken.isEmpty else { return nil }
        let user = spoken.filter { isUserLabel($0.speakerLabel, selfKey: selfKey) }
        let others = spoken.filter { !isUserLabel($0.speakerLabel, selfKey: selfKey) }
        // A meeting where the user never speaks — or where nobody else
        // does (a memo) — has no relationship to coach.
        guard !user.isEmpty, !others.isEmpty else { return nil }

        let userDuration = user.reduce(0.0) { $0 + max(0, $1.endTime - $1.startTime) }
        let totalDuration = spoken.reduce(0.0) { $0 + max(0, $1.endTime - $1.startTime) }
        guard totalDuration > 0 else { return nil }

        // Interruptions: user turns that START strictly inside someone
        // else's segment. Diarization timing is approximate — this counts
        // overlaps, which is the honest name for what it measures.
        let interruptions = user.filter { turn in
            others.contains { turn.startTime > $0.startTime && turn.startTime < $0.endTime }
        }.count

        let userText = user.map(\.text).joined(separator: " ")
        let words = userText.split { $0.isWhitespace || $0.isNewline }
        let wordCount = words.count
        let fillerCount: Int = {
            guard let regex = try? NSRegularExpression(pattern: fillerPattern, options: .caseInsensitive) else { return 0 }
            return regex.numberOfMatches(in: userText, range: NSRange(userText.startIndex..., in: userText))
        }()
        let fillerPer100 = wordCount > 0 ? Double(fillerCount) / Double(wordCount) * 100 : 0

        let sentences = userText
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let questionCount = userText.filter { $0 == "?" }.count
        let questionRate = sentences.isEmpty ? 0 : min(1, Double(questionCount) / Double(sentences.count))

        // Longest monologue: consecutive user segments with <2s gaps.
        var longest = 0.0
        var runStart: Double? = nil
        var runEnd = 0.0
        for seg in user.sorted(by: { $0.startTime < $1.startTime }) {
            if let _ = runStart, seg.startTime - runEnd <= monologueGapSec {
                runEnd = max(runEnd, seg.endTime)
            } else {
                if let start = runStart { longest = max(longest, runEnd - start) }
                runStart = seg.startTime
                runEnd = seg.endTime
            }
        }
        if let start = runStart { longest = max(longest, runEnd - start) }

        return SpeechStats(
            meetingId: meetingId,
            talkShare: userDuration / totalDuration,
            interruptions: interruptions,
            fillerPer100: fillerPer100,
            questionRate: questionRate,
            longestMonologueSec: longest,
            userWordCount: wordCount,
            computedAt: now)
    }

    /// Neutral trend line for a folder: average talk share over the last
    /// N instances, oldest→newest values for the spark bars.
    static func trend(stats: [SpeechStats], orderedMeetingIds: [String], last n: Int = 5) -> (average: Double, points: [Double])? {
        let byId = Dictionary(uniqueKeysWithValues: stats.map { ($0.meetingId, $0) })
        let points = orderedMeetingIds.compactMap { byId[$0]?.talkShare }.suffix(n)
        guard !points.isEmpty else { return nil }
        return (points.reduce(0, +) / Double(points.count), Array(points))
    }
}
