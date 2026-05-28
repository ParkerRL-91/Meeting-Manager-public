import Foundation
import os

/// Generates the AI-narrated daily brief from a `DailyBrief`.
///
/// This is split out from `DailyBriefView` so the prompt + LLM call can be
/// invoked from a background scheduler (AppState) and from the manual
/// "Regenerate" button in the view, without duplicating any of the prompt
/// rules. The View no longer constructs prompts directly.
///
/// Anti-hallucination contract:
/// - The prompt enumerates exactly the meetings, participants, prior-session
///   excerpts, and open action items provided by `DailyBriefService`.
/// - The system prompt forbids inventing attendees, topics, decisions, or
///   prior conversations not present in the input.
/// - Prior-session excerpts that read as "fragmented / incoherent / no
///   meaningful content" are stripped before being shown to the model, so the
///   model isn't tempted to summarize garbage as if it were real signal.
@MainActor
struct DailyBriefAIService {

    enum BriefError: LocalizedError {
        case noAIService

        var errorDescription: String? {
            switch self {
            case .noAIService:
                return "AI is not configured. Add a Claude API key or enable on-device AI."
            }
        }
    }

    /// Result returned to callers, ready to be cached and rendered.
    struct Result: Sendable {
        let text: String
        let model: String
    }

    /// One verifiable KB citation surfaced to the model as `[KBn]`. `body` is the
    /// full chunk text (the model is shown a truncated single-line slice of it);
    /// `verify` confirms any quote the model attaches is a verbatim substring of
    /// this body and that the citation belongs to the meeting it's filed under.
    struct Citation: Sendable {
        let id: String            // "KB1"
        let meetingTitle: String
        let relativePath: String
        let body: String
    }

    /// The assembled user prompt plus the citation table needed to verify the
    /// model's `[KBn]` references after generation.
    struct PreparedPrompt: Sendable {
        let userPrompt: String
        let citations: [String: Citation]
    }

    // MARK: - Public entry point

    /// Generates a daily brief. Picks Claude if a key is present, else Ollama
    /// if reachable, else throws `BriefError.noAIService`.
    func generate(
        for brief: DailyBrief,
        claudeAPIKey: String?,
        claudeModel: String,
        ollama: OllamaService,
        ollamaModel: String,
        date: Date
    ) async throws -> Result {
        let prepared = Self.buildUserPrompt(for: brief, date: date)
        // The KB clause only applies when there are notes to cite, so a brief
        // with no KB background produces byte-identical output to before.
        let system = prepared.citations.isEmpty ? Self.systemPrompt : Self.systemPromptWithKB

        if let key = claudeAPIKey, !key.isEmpty {
            let claude = ClaudeService()
            let raw = try await claude.sendMessage(
                systemPrompt: system,
                userPrompt: prepared.userPrompt,
                model: claudeModel
            )
            return Result(text: Self.verify(text: raw, citations: prepared.citations), model: claudeModel)
        }

        // think:true — Qwen3 with think:false still leaks chain-of-thought into
        // the content field on rule-heavy prompts. With think:true, reasoning
        // goes into the separate `thinking` field and the actual brief lands
        // cleanly in `content`. OllamaService.stripThinkBlock handles any
        // stray dangling </think> if the model ever inlines a tag.
        if ollama.isReachable {
            let raw = try await ollama.generate(
                systemPrompt: system,
                userPrompt: prepared.userPrompt,
                model: ollamaModel,
                think: true,
                jsonMode: false
            )
            return Result(text: Self.verify(text: raw, citations: prepared.citations), model: ollamaModel)
        }

        throw BriefError.noAIService
    }

    // MARK: - Prompt construction

    static let systemPrompt: String = """
        You write a one-person morning briefing.

        Output only the brief itself in Markdown. No preamble, no commentary about the rules. \
        The first line of your reply is the literal text "## Today's read". The last line is the \
        final bullet of "## Day-end goals". Anything else is wrong output.

        Facts: copy attendees, titles, and times verbatim from INPUT. Never invent topics, \
        decisions, action items, prior conversations, or commitments that are not in INPUT.
        """

    /// Used only when the brief has KB notes to cite. Adds the verbatim-only
    /// citation discipline on top of the base rules. Kept separate so the
    /// no-KB path is unchanged.
    static let systemPromptWithKB: String = systemPrompt + """


        Knowledge-base notes: each note is tagged with an id like [KB1]. You may surface a note \
        only inside a Background sub-bullet of the exact form `    - Background: "<exact quote>" [KB1]`. \
        The quoted text must be copied verbatim from one of the notes listed under that same meeting, \
        and the [KB1] tag must be that note's id. Never paraphrase a note, never merge two notes, \
        never attach a note to a meeting it was not listed under, and never state a knowledge-base \
        fact anywhere except inside a Background sub-bullet.
        """

    /// Hard cap on cited notes across the whole brief, to bound prompt size and
    /// keep the brief skimmable when many meetings carry KB background.
    private static let maxCitations = 12

    /// Build the user-side prompt + citation table. Public so we can persona-eval
    /// it in tests.
    static func buildUserPrompt(for brief: DailyBrief, date: Date) -> PreparedPrompt {
        let dateStr = date.formatted(date: .complete, time: .omitted)
        let timeFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            return f
        }()

        var scheduleLines: [String] = []
        var openItemsLines: [String] = []
        var hasUsefulCarryOver = false

        // KB background, scoped per meeting and tagged [KBn] for verifiable
        // citation. `citations` is the source of truth `verify` checks against.
        var citations: [String: Citation] = [:]
        var backgroundBlocks: [String] = []
        var citationCounter = 0

        for entry in brief.meetings {
            let meeting = entry.meeting
            // Filter blank/placeholder meetings out of the schedule entirely —
            // they're just noise. "Home" is filtered upstream by the calendar
            // service; this catches "Untitled Event" and the like.
            let title = meeting.title.trimmingCharacters(in: .whitespaces)
            let lowerTitle = title.lowercased()
            if title.isEmpty || lowerTitle == "untitled event" || lowerTitle == "untitled" || lowerTitle == "home" {
                continue
            }

            let start = meeting.scheduledStartDate ?? meeting.startDate
            let end = meeting.scheduledEndDate
            let timeStr: String
            if let start, let end {
                timeStr = "\(timeFmt.string(from: start))–\(timeFmt.string(from: end))"
            } else if let start {
                timeStr = timeFmt.string(from: start)
            } else {
                timeStr = "Time TBD"
            }

            let participants = entry.prepBrief.participants
                .prefix(4)
                .joined(separator: ", ")

            // Previous-session excerpt — only include when it's actually useful.
            // Cleaning happens first so the carry-over tag is dropped when the
            // prior summary turns out to be noise (failed recording, fragmented
            // transcript, etc.). Better to look like "no prior context" than
            // to hand the model misleading signal.
            var cleanedPrior: String? = nil
            if let prev = entry.prepBrief.previousSession,
               let raw = prev.summaryExcerpt,
               let cleaned = cleanPriorExcerpt(raw) {
                cleanedPrior = cleaned
            }

            var line = "- **\(timeStr)** — \(title)"
            if !participants.isEmpty { line += " · \(participants)" }
            if cleanedPrior != nil || !entry.prepBrief.openActionItems.isEmpty {
                line += " *(carry-over)*"
                hasUsefulCarryOver = true
            }
            scheduleLines.append(line)

            if let prev = entry.prepBrief.previousSession, let cleaned = cleanedPrior {
                let dateStr = prev.date.formatted(.dateTime.month(.abbreviated).day())
                scheduleLines.append("    - Last time (\(dateStr)): \(cleaned)")
            }

            // Open items
            for item in entry.prepBrief.openActionItems.prefix(3) {
                var li = "- "
                if let assignee = item.assignee, !assignee.isEmpty {
                    li += "**\(assignee)** — "
                }
                li += item.title
                li += " *(from \(title))*"
                openItemsLines.append(li)
            }

            // KB background for this meeting. Each chunk gets a stable [KBn] id
            // the model must cite; the full body is retained in `citations` so
            // `verify` can confirm any quote is verbatim. The model is shown a
            // truncated single-line slice, so it can only quote what fits.
            if !entry.kbChunks.isEmpty {
                var noteLines: [String] = []
                for chunk in entry.kbChunks {
                    guard citationCounter < maxCitations else { break }
                    citationCounter += 1
                    let id = "KB\(citationCounter)"
                    citations[id] = Citation(
                        id: id,
                        meetingTitle: title,
                        relativePath: chunk.relativePath,
                        body: chunk.body
                    )
                    noteLines.append("[\(id)] (\(chunk.relativePath)) \(singleLineExcerpt(chunk.body, limit: 280))")
                }
                if !noteLines.isEmpty {
                    backgroundBlocks.append("For \"\(title)\":\n" + noteLines.joined(separator: "\n"))
                }
            }
        }

        let scheduleBlock = scheduleLines.isEmpty
            ? "(no meetings on the calendar)"
            : scheduleLines.joined(separator: "\n")
        let openItemsBlock = openItemsLines.isEmpty
            ? "(no open action items)"
            : openItemsLines.joined(separator: "\n")

        let attentionInstruction: String
        if openItemsLines.isEmpty && !hasUsefulCarryOver {
            attentionInstruction = """
                There are no open items and no usable carry-over context today. \
                Write the single line: "Nothing carried over from previous meetings."
                """
        } else {
            attentionInstruction = """
                Two to four bullets. Each bullet names the meeting in **bold**, \
                quotes or directly paraphrases a specific item from "Open action items" \
                or from that meeting's "Last time" excerpt, and ends with the prep step \
                the excerpt itself implies. Do not invent prep steps that are not grounded \
                in a specific sentence above.
                """
        }

        let hasKB = !citations.isEmpty
        let backgroundBlock = backgroundBlocks.joined(separator: "\n\n")

        // KB-conditional fragments. Built as explicit strings (not slices of a
        // multiline literal) so the rendered prompt's indentation is exact and
        // independent of source formatting. All empty when there's no KB, so the
        // no-KB prompt is byte-for-byte the prior version.
        let exampleBackgroundInput = hasKB
            ? "\n\n### Background notes from your knowledge base\nFor \"Acme renewal\":\n[KB1] (vendors/acme.md) Acme requires SOC 2 Type II before signing any enterprise agreement; security review is owned by their CISO."
            : ""
        let exampleBackgroundBullet = hasKB
            ? "\n    - Background: \"Acme requires SOC 2 Type II before signing any enterprise agreement\" [KB1]"
            : ""
        let backgroundInputSection = hasKB
            ? "\n\n### Background notes from your knowledge base\nEach note belongs to the meeting it is listed under. Quote verbatim; never paraphrase a note or reuse it across meetings.\n\(backgroundBlock)"
            : ""
        let backgroundRule = hasKB
            ? "\n- **Background sub-bullet**: when a meeting has notes listed under \"Background notes from your knowledge base\", add exactly one indented sub-bullet beneath that meeting's line, formatted `    - Background: \"<exact quote>\" [KBn]`. Copy the quote verbatim from one of *that meeting's own* listed notes and cite its [KBn] id. If a meeting has no listed notes, add no Background sub-bullet. Never state a knowledge-base fact anywhere except inside a Background sub-bullet."
            : ""

        let userPrompt = """
        Here is an example showing the exact shape you must produce.

        EXAMPLE INPUT
        Today: Monday, January 6, 2025

        ### Today's schedule
        - **9:00 AM–9:30 AM** — Engineering standup · Sam Lee, Priya Patel, Jordan Kim
        - **11:00 AM–12:00 PM** — Acme renewal · Alex Chen (Acme), Sam Lee *(carry-over)*
            - Last time (Dec 20): Acme asked for a 12-month proposal with volume discount above 50 seats; Alex committed to send procurement contact this week.
        - **2:00 PM–2:30 PM** — Candidate intro — Jane Doe · Jane Doe

        ### Open action items carried in
        - **Sam Lee** — Send Acme volume-discount proposal *(from Acme renewal)*\(exampleBackgroundInput)

        EXAMPLE OUTPUT
        ## Today's read
        The Acme renewal at 11 AM is the day's pivot — the volume-discount proposal is due and Alex is waiting on the procurement contact.

        ## What needs attention
        - **Acme renewal** — Sam owes the volume-discount proposal Alex requested on Dec 20; bring a draft and the procurement contact you confirmed.

        ## Meeting-by-meeting
        - **9:00 AM–9:30 AM** **Engineering standup** — First conversation — no prior context.
        - **11:00 AM–12:00 PM** **Acme renewal** — Alex committed Dec 20 to send the procurement contact this week and asked for a 12-month proposal with volume discount above 50 seats.\(exampleBackgroundBullet)
        - **2:00 PM–2:30 PM** **Candidate intro — Jane Doe** — First conversation — no prior context.

        ## Day-end goals
        - Send Sam's Acme volume-discount proposal before EOD to close the loop from Dec 20.
        - Capture a clear go/no-go on Jane Doe after the 2 PM intro.

        END OF EXAMPLE

        Now produce the brief for the real INPUT below. Same four sections, same shape. Length 150–250 words.

        ## INPUT

        Today: \(dateStr)

        ### Today's schedule
        \(scheduleBlock)

        ### Open action items carried in
        \(openItemsBlock)\(backgroundInputSection)

        Section rules for the real output:
        - **What needs attention**: \(attentionInstruction)
        - **Meeting-by-meeting**: one bullet per meeting in order. If a meeting has no "Last time" excerpt above, write exactly "First conversation — no prior context." for that bullet.\(backgroundRule)
        - **Day-end goals**: two or three bullets, each tied to a meeting from the schedule.

        Begin your response with the literal line "## Today's read".
        """

        return PreparedPrompt(userPrompt: userPrompt, citations: citations)
    }

    // MARK: - Excerpt hygiene

    /// Strips markdown headings and obvious noise from a prior-session summary
    /// excerpt before showing it to the model. Returns `nil` when the excerpt
    /// reads as "no real content" — we'd rather the model say "First
    /// conversation" than invent meaning from garbage.
    static func cleanPriorExcerpt(_ raw: String, limit: Int = 400) -> String? {
        // Drop heading lines and quote lines, collapse whitespace.
        let kept = raw.split(whereSeparator: { $0.isNewline }).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && !t.hasPrefix(">") && !t.hasPrefix("- **") && !t.isEmpty
        }
        var s = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading TL;DR token
        for prefix in ["TL;DR", "Tl;dr", "tl;dr"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :—-"))
                break
            }
        }
        // Heuristic: if the excerpt is mostly "no decisions / no action items
        // / fragmented / incoherent" filler, treat as empty. One hit is
        // enough — these phrases are not produced in well-formed summaries.
        let lower = s.lowercased()
        let noisePhrases = [
            "no meaningful summary",
            "no meaningful discussion",
            "no meaningful decisions",
            "no decisions or action items",
            "no formal decisions reached",
            "fragmented and incoherent",
            "fragmented thoughts",
            "fragmented with",
            "lack of coherent content",
            "no clear discussion topics",
            "no clear topics",
            "no action items captured",
            "no decisions were captured",
            "no meaningful content",
            "largely unstructured",
            "lacked clear focus",
            "unclear references",
            "repeated questions",
            "key unresolved issue remains"
        ]
        if noisePhrases.contains(where: { lower.contains($0) }) { return nil }

        s = s.replacingOccurrences(of: "  ", with: " ")
        if s.count > limit {
            s = String(s.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return s.isEmpty ? nil : s
    }

    /// Collapse a KB chunk body to a single bounded line for display in the
    /// prompt. The model can only quote what it's shown, so a truncated slice
    /// caps how much of a note can land in the brief; `verify` still checks the
    /// quote against the full body.
    static func singleLineExcerpt(_ s: String, limit: Int) -> String {
        let collapsed = s
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Citation verification

    /// Verify the model's `[KBn]` references against the citation table and
    /// strip anything it can't prove. This is the structural anti-hallucination
    /// gate for KB-grounded briefs — the same philosophy as ADR-005: don't trust
    /// the prompt to prevent fabrication, catch it deterministically afterward.
    ///
    /// A line carrying a `[KBn]` marker survives only when it contains a quote
    /// (≥ 8 normalized chars) that is a verbatim substring of a cited chunk's
    /// body AND that chunk's meeting shares a distinctive term with the meeting
    /// bullet the line sits under (misattribution guard). On failure:
    ///   - an indented Background sub-bullet is dropped entirely;
    ///   - a top-level line keeps its text but loses the unverifiable marker.
    /// Surviving citations are listed in a `_Sources: …_` footer for provenance.
    static func verify(text rawText: String, citations: [String: Citation]) -> String {
        // Nothing to check and nothing claimed → return untouched.
        if citations.isEmpty && !rawText.contains("[KB") { return rawText }

        let markerRegex = try? NSRegularExpression(pattern: "\\[(KB\\d+)\\]")
        let lines = rawText.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var lastTopBullet = ""
        var usedPaths: [String] = []   // ordered, de-duplicated

        for line in lines {
            let leadingWS = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isSubBullet = leadingWS > 0 && trimmed.hasPrefix("-")
            let isTopBullet = leadingWS == 0 && trimmed.hasPrefix("- ")

            let ns = line as NSString
            let matches = markerRegex?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? []

            if matches.isEmpty {
                if isTopBullet { lastTopBullet = trimmed }
                out.append(line)
                continue
            }

            let ids = matches.map { ns.substring(with: $0.range(at: 1)) }
            let quote = firstQuotedSpan(in: line).map(normForMatch)

            var validID: String? = nil
            if let qn = quote, qn.count >= 8 {
                for id in ids {
                    guard let c = citations[id] else { continue }
                    guard normForMatch(c.body).contains(qn) else { continue }
                    // Misattribution guard: the cited note's meeting must share a
                    // distinctive term with the meeting bullet this line sits
                    // under. Skipped when the title has no distinctive term.
                    let titleTerms = KnowledgeBaseService.distinctiveTerms(in: c.meetingTitle)
                    if !titleTerms.isEmpty,
                       titleTerms.isDisjoint(with: KnowledgeBaseService.distinctiveTerms(in: lastTopBullet)) {
                        continue
                    }
                    validID = id
                    break
                }
            }

            if let vid = validID {
                var cleaned = line
                for id in Set(ids) where id != vid {
                    cleaned = cleaned.replacingOccurrences(of: "[\(id)]", with: "")
                }
                cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
                out.append(cleaned)
                if let c = citations[vid], !usedPaths.contains(c.relativePath) {
                    usedPaths.append(c.relativePath)
                }
                if isTopBullet { lastTopBullet = trimmed }
            } else if isSubBullet {
                // Unverifiable Background sub-bullet → drop it.
                continue
            } else {
                // Unverifiable marker on a main line → keep text, strip markers.
                var cleaned = line
                for id in Set(ids) {
                    cleaned = cleaned.replacingOccurrences(of: "[\(id)]", with: "")
                }
                cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
                if isTopBullet { lastTopBullet = trimmed }
                out.append(cleaned)
            }
        }

        var result = out.joined(separator: "\n")
        if !usedPaths.isEmpty {
            result += "\n\n_Sources: " + usedPaths.joined(separator: ", ") + "_"
        }
        return result
    }

    /// First double-quoted span on a line — straight quotes first, then smart
    /// quotes. Returns the inner text without the quote characters.
    static func firstQuotedSpan(in line: String) -> String? {
        if let r = line.range(of: "\"[^\"]{1,400}\"", options: .regularExpression) {
            return String(line[r].dropFirst().dropLast())
        }
        if let open = line.firstIndex(of: "\u{201C}") {
            let after = line.index(after: open)
            if let close = line[after...].firstIndex(of: "\u{201D}") {
                return String(line[after..<close])
            }
        }
        return nil
    }

    /// Lowercase, map every run of non-alphanumerics to a single space, trim.
    /// Makes the verbatim-quote check tolerant of punctuation / smart-quote
    /// differences while still requiring the same words in the same order.
    static func normForMatch(_ s: String) -> String {
        var chars: [Character] = []
        var pendingSpace = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingSpace && !chars.isEmpty { chars.append(" ") }
                chars.append(ch)
                pendingSpace = false
            } else {
                pendingSpace = true
            }
        }
        return String(chars)
    }
}
