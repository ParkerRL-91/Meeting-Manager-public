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

    /// Richer result for the AI-primary "Create with AI" compose flow (TASK-111).
    /// Unlike `Result` (used by the instant quick-add), this also carries recurrence,
    /// an assignee, a due-time flag, and whether the AI was actually used — so the
    /// compose preview can show a fully filled-out, editable task and degrade visibly
    /// to the deterministic parse offline. `assignee` is a name STRING only; Person
    /// linkage (`assigneePersonId`) is resolved in the view at commit, never here, so
    /// the parser stays pure and DB-free.
    struct ComposeResult: Equatable {
        var title: String
        var dueDate: Date?
        var dueHasTime: Bool
        var priority: Int
        var tags: [String]
        var assignee: String?
        var recurrence: TaskRecurrenceRule?
        var aiUsed: Bool
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

    // MARK: - AI-primary compose (PRJ-015 / TASK-111)

    /// Deterministic seed for the compose flow: the existing `parse()` (title / date /
    /// priority / #tags) plus a minimal recurrence detect, returned as a `ComposeResult`
    /// with `aiUsed = false`. Also strips a trailing orphan "every" left over when
    /// `parse()` removes a bare weekday from "…every Monday" — scoped to exactly "every"
    /// (the only connector `parse()` ever orphans; date prefixes are removed glued to
    /// their phrase) and gated on a date/recurrence phrase actually being removed, so a
    /// legitimate trailing word ("follow up on", "presenting at") is never clipped.
    func composeBase(_ raw: String) -> ComposeResult {
        let parsed = parse(raw)
        let recurrence = detectRecurrence(in: raw)
        var title = parsed.title
        if parsed.dueDate != nil || recurrence != nil {
            title = Self.stripTrailingEvery(from: title)
        }
        // Sentence-case the first letter so the offline/deterministic preview reads as a
        // proper task ("Send Joel the document", not "send …"); proper nouns mid-title are
        // left to the AI path, which capitalizes them.
        title = Self.sentenceCased(title)
        return ComposeResult(
            title: title,
            dueDate: parsed.dueDate,
            dueHasTime: false,
            priority: parsed.priority,
            tags: parsed.tags,
            assignee: nil,
            recurrence: recurrence,
            aiUsed: false
        )
    }

    /// Minimal, pure recurrence detector. Recognises "every N day|week|month|year(s)"
    /// and the single-word / "every <unit>" forms (daily / weekly / monthly / yearly).
    /// Never sets an end date — "until …" is left to the AI, which merges field-wise.
    func detectRecurrence(in raw: String) -> TaskRecurrenceRule? {
        let lower = raw.lowercased()
        if let regex = try? NSRegularExpression(pattern: #"every\s+(\d+)\s+(day|week|month|year)s?"#, options: .caseInsensitive) {
            let range = NSRange(lower.startIndex..., in: lower)
            if let m = regex.firstMatch(in: lower, range: range),
               let nRange = Range(m.range(at: 1), in: lower),
               let unitRange = Range(m.range(at: 2), in: lower),
               let n = Int(lower[nRange]) {
                return TaskRecurrenceRule(frequency: Self.frequency(forUnit: String(lower[unitRange])), interval: max(1, n))
            }
        }
        let phrases: [(String, TaskRecurrenceRule.Frequency)] = [
            ("every day", .daily), ("daily", .daily),
            ("every week", .weekly), ("weekly", .weekly),
            ("every month", .monthly), ("monthly", .monthly),
            ("every year", .yearly), ("yearly", .yearly), ("annually", .yearly)
        ]
        for (phrase, freq) in phrases where Self.containsWord(phrase, in: lower) {
            return TaskRecurrenceRule(frequency: freq, interval: 1)
        }
        return nil
    }

    /// AI-primary compose: extracts the full structured task (title, due date + optional
    /// time, recurrence, priority, tags, assignee) from a plain-English phrase, seeded by
    /// `base`. Fill-gaps semantics — the AI never clobbers a confident deterministic value;
    /// recurrence is merged field-wise (deterministic freq/interval authoritative, AI fills
    /// a missing end date). Sets `aiUsed = true` on success. ANY failure / no generator /
    /// timeout / cancellation ⇒ returns `base` (aiUsed = false). Bounded by `timeout` and
    /// cooperatively cancellable so a cancelled parse never races to commit.
    ///
    /// `// EXEMPT: user-initiated/instant` — the compose path is a user-driven modal and
    /// must not go through TaskQueueManager; it degrades to the deterministic parse offline.
    func aiCompose(
        raw: String,
        base: ComposeResult,
        textGenerator: ((String, String) async throws -> String)?,
        timeout: TimeInterval = 14
    ) async -> ComposeResult {
        guard let textGenerator else { return base }

        let system = """
        You extract a SINGLE task from a short natural-language phrase. Reply with ONLY a compact JSON \
        object and nothing else. Keys: "title" (the task action with date/recurrence/priority words \
        removed, keep the substance), "dueDate" (ISO-8601 "yyyy-MM-dd" or null), "dueTime" ("HH:mm" \
        24-hour or null), "priority" (integer 0-4 where 0 none and 4 urgent), "tags" (array of strings, \
        may be empty), "assignee" (string or null), "recurrence" (object \
        {"frequency":"daily|weekly|monthly|yearly","interval":integer,"endDate":"yyyy-MM-dd" or null} \
        or null when the task is one-off). Today is \(Self.isoDay.string(from: now)). Do not invent \
        values that are not implied, and never return a due date in the past. Only set "assignee" when \
        the sentence makes ANOTHER person responsible for doing the task (e.g. "ask Dana to…", \
        "have Sam review…"). If the named person is a recipient or beneficiary (e.g. "send Joel the \
        doc"), leave "assignee" null — the task belongs to the author.
        """
        let user = "Task phrase: \(raw)"

        do {
            let response = try await withThrowingTimeout(seconds: timeout) {
                try await textGenerator(system, user)
            }
            try Task.checkCancellation()
            guard let ai = decodeComposeResponse(response) else { return base }
            var result = base
            result.aiUsed = true
            if result.dueDate == nil, let aiDue = ai.dueDate {
                result.dueDate = aiDue
                result.dueHasTime = ai.dueHasTime
            }
            if result.priority == 0, let p = ai.priority {
                result.priority = max(0, min(p, 4))
            }
            if result.tags.isEmpty, let aiTags = ai.tags, !aiTags.isEmpty {
                result.tags = aiTags
            }
            if result.assignee == nil, let aiAssignee = ai.assignee, !aiAssignee.isEmpty {
                result.assignee = aiAssignee
            }
            // Recurrence: field-wise merge. Keep a deterministic freq/interval (authoritative)
            // but fill a missing end date from the AI; take the AI rule whole when the seed has none.
            if let aiRec = ai.recurrence {
                if var seed = result.recurrence {
                    if seed.endDate == nil { seed.endDate = aiRec.endDate }
                    result.recurrence = seed
                } else {
                    result.recurrence = aiRec
                }
            }
            // Title: fill-only — keep the deterministic title unless it's empty or the
            // deterministic pass only echoed the raw phrase (case-insensitive, since the seed
            // is now sentence-cased). When it echoed raw, the cleaner AI title wins.
            let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let aiTitle = ai.title, !aiTitle.isEmpty,
               (result.title.isEmpty || result.title.caseInsensitiveCompare(trimmedRaw) == .orderedSame) {
                result.title = aiTitle
            }
            return result
        } catch {
            return base
        }
    }

    // MARK: - Compose helpers

    private struct ComposeAIFields {
        var title: String?
        var dueDate: Date?
        var dueHasTime: Bool
        var priority: Int?
        var tags: [String]?
        var assignee: String?
        var recurrence: TaskRecurrenceRule?
    }

    /// Instance method (not `static` like `decodeAIResponse`) because it needs `self.calendar`
    /// and `self.now` to apply a due time and the past-date guard. Reaches the shared date
    /// formatter as `Self.isoDay` rather than adding a duplicate.
    private func decodeComposeResponse(_ text: String) -> ComposeAIFields? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var due: Date?
        var dueHasTime = false
        if let s = obj["dueDate"] as? String, !s.isEmpty,
           let day = Self.isoDay.date(from: String(s.prefix(10))) {
            due = day
            if let t = obj["dueTime"] as? String, let withTime = applyTime(t, to: day) {
                due = withTime
                dueHasTime = true
            }
            // Past-date guard: never auto-create a silently-overdue task.
            if let d = due, d < calendar.startOfDay(for: now) {
                due = nil
                dueHasTime = false
            }
        }

        let priority = obj["priority"] as? Int
        let tags = (obj["tags"] as? [Any])?.compactMap { $0 as? String }
        let assignee = (obj["assignee"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var recurrence: TaskRecurrenceRule?
        if let rec = obj["recurrence"] as? [String: Any],
           let freqStr = rec["frequency"] as? String,
           let freq = TaskRecurrenceRule.Frequency(rawValue: freqStr.lowercased()) {
            var endDate: Date?
            if let e = rec["endDate"] as? String, !e.isEmpty {
                endDate = Self.isoDay.date(from: String(e.prefix(10)))
            }
            recurrence = TaskRecurrenceRule(frequency: freq, interval: max(1, (rec["interval"] as? Int) ?? 1), endDate: endDate)
        }

        return ComposeAIFields(
            title: (title?.isEmpty == false) ? title : nil,
            dueDate: due,
            dueHasTime: dueHasTime,
            priority: priority,
            tags: tags,
            assignee: (assignee?.isEmpty == false) ? assignee : nil,
            recurrence: recurrence
        )
    }

    private func applyTime(_ hhmm: String, to day: Date) -> Date? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return calendar.date(bySettingHour: h, minute: m, second: 0, of: day)
    }

    private static func frequency(forUnit unit: String) -> TaskRecurrenceRule.Frequency {
        switch unit {
        case "week": return .weekly
        case "month": return .monthly
        case "year": return .yearly
        default: return .daily
        }
    }

    private static func containsWord(_ phrase: String, in text: String) -> Bool {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func stripTrailingEvery(from title: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\s+every\s*$"#, options: .caseInsensitive) else { return title }
        let range = NSRange(title.startIndex..., in: title)
        return regex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uppercases only the first character, leaving the rest untouched.
    private static func sentenceCased(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
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
