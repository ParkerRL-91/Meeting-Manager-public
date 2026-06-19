import Foundation

/// Deterministic natural-language parse for quick-add (PRJ-013 Phase 6). Pulls a
/// due date, a priority, and `#tags` out of a free-text title and returns the
/// remainder as the cleaned task title. Runs offline and instantly, so a parse
/// failure simply leaves the phrase in the title.
///
/// PRJ-013 Phase 7 layers an optional AI assist (`aiEnhance`) on top: when a text
/// generator is available it can recover a due date the deterministic pass missed
/// (e.g. "end of the month", "in three days"). The deterministic result is always
/// the floor — the assist only fills gaps and is bounded by a short timeout so the
/// path stays instant and degrades gracefully offline.
struct TaskQuickAddParser {
    struct Result: Equatable {
        var title: String
        var dueDate: Date?
        var priority: Int
        var tags: [String]
    }

    private let calendar: Calendar
    private let now: Date

    init(calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.now = now
    }

    func parse(_ raw: String) -> Result {
        var working = " \(raw) "
        var tags: [String] = []
        var priority = 0
        var dueDate: Date?

        // #tags — strip and collect.
        let tagPattern = #"\s#([\p{L}0-9_-]+)"#
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            let matches = regex.matches(in: working, range: NSRange(working.startIndex..., in: working))
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: working) {
                    tags.insert(String(working[range]), at: 0)
                }
                if let full = Range(match.range, in: working) {
                    working.replaceSubrange(full, with: " ")
                }
            }
        }

        // Priority phrases — first hit wins, longest phrases first.
        let priorityPhrases: [(String, Int)] = [
            ("!!!", 4), ("!!", 3),
            ("urgent", 4), ("p1", 4), ("asap", 4),
            ("high priority", 3), ("high-priority", 3), ("p2", 3),
            ("medium priority", 2), ("p3", 2),
            ("low priority", 1), ("p4", 1)
        ]
        for (phrase, level) in priorityPhrases {
            if let stripped = removePhrase(phrase, from: working) {
                working = stripped
                priority = level
                break
            }
        }

        // Date phrases — first hit wins. Each returns a start-of-day date.
        let dayPhrases: [(String, () -> Date?)] = [
            ("the day after tomorrow", { self.dayOffset(2) }),
            ("day after tomorrow", { self.dayOffset(2) }),
            ("tomorrow", { self.dayOffset(1) }),
            ("today", { self.dayOffset(0) }),
            ("tonight", { self.dayOffset(0) }),
            ("this weekend", { self.nextWeekend() }),
            ("next week", { self.dayOffset(7) }),
            ("next monday", { self.nextWeekday(2) }),
            ("next tuesday", { self.nextWeekday(3) }),
            ("next wednesday", { self.nextWeekday(4) }),
            ("next thursday", { self.nextWeekday(5) }),
            ("next friday", { self.nextWeekday(6) }),
            ("next saturday", { self.nextWeekday(7) }),
            ("next sunday", { self.nextWeekday(1) }),
            ("monday", { self.nextWeekday(2) }),
            ("tuesday", { self.nextWeekday(3) }),
            ("wednesday", { self.nextWeekday(4) }),
            ("thursday", { self.nextWeekday(5) }),
            ("friday", { self.nextWeekday(6) }),
            ("saturday", { self.nextWeekday(7) }),
            ("sunday", { self.nextWeekday(1) })
        ]
        for (phrase, resolve) in dayPhrases {
            // Match "due <phrase>", "by <phrase>", "on <phrase>", or bare phrase.
            for prefix in ["due ", "by ", "on ", ""] {
                if let stripped = removePhrase(prefix + phrase, from: working) {
                    working = stripped
                    dueDate = resolve()
                    break
                }
            }
            if dueDate != nil { break }
        }

        let title = working
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Result(
            title: title.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : title,
            dueDate: dueDate,
            priority: priority,
            tags: tags
        )
    }

    // MARK: - Helpers

    /// Removes the first case-insensitive, word-bounded occurrence of `phrase`.
    /// Returns the new string, or nil if the phrase wasn't present.
    private func removePhrase(_ phrase: String, from text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        // Word boundaries only when the phrase begins/ends with a word char so "!!"
        // and "p1" still match next to spaces.
        let lead = phrase.first.map { $0.isLetter || $0.isNumber } ?? false ? #"(?<=\s)"# : ""
        let trail = phrase.last.map { $0.isLetter || $0.isNumber } ?? false ? #"(?=\s)"# : ""
        let pattern = lead + escaped + trail
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        var copy = text
        copy.replaceSubrange(r, with: " ")
        return copy
    }

    private func dayOffset(_ days: Int) -> Date? {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
    }

    /// The next occurrence of `weekday` (1 = Sunday … 7 = Saturday) strictly after
    /// today; if today matches, jumps a full week so "Friday" never means today.
    private func nextWeekday(_ weekday: Int) -> Date? {
        let start = calendar.startOfDay(for: now)
        for offset in 1...7 {
            if let candidate = calendar.date(byAdding: .day, value: offset, to: start),
               calendar.component(.weekday, from: candidate) == weekday {
                return candidate
            }
        }
        return nil
    }

    /// Upcoming Saturday (start of the weekend).
    private func nextWeekend() -> Date? { nextWeekday(7) }

    // MARK: - Optional AI assist (PRJ-013 Phase 7)

    /// Refines a deterministic `Result` using the AI text generator, filling only
    /// gaps the deterministic pass left (a missing due date or priority). The
    /// deterministic result is the floor: the assist never overrides a value the
    /// regex pass already found, and any failure (offline, malformed JSON, timeout)
    /// returns `base` unchanged. Bounded by `timeout` so quick-add stays instant.
    ///
    /// `// EXEMPT: user-initiated/instant` — the quick-add path is user-driven and
    /// must not go through TaskQueueManager (which is for background post-meeting
    /// work). Degrades gracefully when no backend is configured.
    func aiEnhance(
        raw: String,
        base: Result,
        textGenerator: ((String, String) async throws -> String)?,
        timeout: TimeInterval = 4.0
    ) async -> Result {
        guard let textGenerator else { return base }
        // Nothing left to recover — skip the round-trip.
        if base.dueDate != nil && base.priority > 0 { return base }

        let system = """
        You extract scheduling metadata from a short task phrase. Reply with ONLY a \
        compact JSON object and nothing else. Keys: "dueDate" (ISO-8601 date \
        "yyyy-MM-dd" or null), "priority" (integer 0-4 where 0 none, 4 urgent), \
        "title" (the task text with any date/priority words removed). Today is \
        \(Self.isoDay.string(from: now)). Do not invent a date that is not implied.
        """
        let user = "Task phrase: \(raw)"

        do {
            let response = try await withThrowingTimeout(seconds: timeout) {
                try await textGenerator(system, user)
            }
            guard let parsed = Self.decodeAIResponse(response) else { return base }
            var result = base
            if result.dueDate == nil, let aiDue = parsed.dueDate {
                result.dueDate = aiDue
            }
            if result.priority == 0, let aiPriority = parsed.priority {
                result.priority = max(0, min(aiPriority, 4))
            }
            // Keep the deterministic title unless it is empty/equal to raw and the
            // AI returned a cleaner one.
            if let aiTitle = parsed.title,
               !aiTitle.isEmpty,
               (result.title.isEmpty || result.title == raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                result.title = aiTitle
            }
            return result
        } catch {
            return base
        }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func decodeAIResponse(_ text: String) -> (dueDate: Date?, priority: Int?, title: String?)? {
        // Tolerate prose around the JSON object.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var due: Date?
        if let s = obj["dueDate"] as? String, !s.isEmpty {
            due = isoDay.date(from: String(s.prefix(10)))
        }
        let priority = obj["priority"] as? Int
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (due, priority, title)
    }
}

/// Runs `operation` but throws if it exceeds `seconds`. Used to bound the optional
/// AI assist so quick-add never blocks (PRJ-013 Phase 7).
private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
