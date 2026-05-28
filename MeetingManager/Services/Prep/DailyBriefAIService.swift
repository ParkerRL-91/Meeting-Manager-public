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
        let userPrompt = Self.buildUserPrompt(for: brief, date: date)
        let system = Self.systemPrompt

        if let key = claudeAPIKey, !key.isEmpty {
            let claude = ClaudeService()
            let text = try await claude.sendMessage(
                systemPrompt: system,
                userPrompt: userPrompt,
                model: claudeModel
            )
            return Result(text: text, model: claudeModel)
        }

        // think:true — Qwen3 with think:false still leaks chain-of-thought into
        // the content field on rule-heavy prompts. With think:true, reasoning
        // goes into the separate `thinking` field and the actual brief lands
        // cleanly in `content`. OllamaService.stripThinkBlock handles any
        // stray dangling </think> if the model ever inlines a tag.
        if ollama.isReachable {
            let text = try await ollama.generate(
                systemPrompt: system,
                userPrompt: userPrompt,
                model: ollamaModel,
                think: true,
                jsonMode: false
            )
            return Result(text: text, model: ollamaModel)
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

    /// Build the user-side prompt. Public so we can persona-eval it in tests.
    static func buildUserPrompt(for brief: DailyBrief, date: Date) -> String {
        let dateStr = date.formatted(date: .complete, time: .omitted)
        let timeFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            return f
        }()

        var scheduleLines: [String] = []
        var openItemsLines: [String] = []
        var hasUsefulCarryOver = false

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

        return """
        Here is an example showing the exact shape you must produce.

        EXAMPLE INPUT
        Today: Monday, January 6, 2025

        ### Today's schedule
        - **9:00 AM–9:30 AM** — Engineering standup · Sam Lee, Priya Patel, Jordan Kim
        - **11:00 AM–12:00 PM** — Acme renewal · Alex Chen (Acme), Sam Lee *(carry-over)*
            - Last time (Dec 20): Acme asked for a 12-month proposal with volume discount above 50 seats; Alex committed to send procurement contact this week.
        - **2:00 PM–2:30 PM** — Candidate intro — Jane Doe · Jane Doe

        ### Open action items carried in
        - **Sam Lee** — Send Acme volume-discount proposal *(from Acme renewal)*

        EXAMPLE OUTPUT
        ## Today's read
        The Acme renewal at 11 AM is the day's pivot — the volume-discount proposal is due and Alex is waiting on the procurement contact.

        ## What needs attention
        - **Acme renewal** — Sam owes the volume-discount proposal Alex requested on Dec 20; bring a draft and the procurement contact you confirmed.

        ## Meeting-by-meeting
        - **9:00 AM–9:30 AM** **Engineering standup** — First conversation — no prior context.
        - **11:00 AM–12:00 PM** **Acme renewal** — Alex committed Dec 20 to send the procurement contact this week and asked for a 12-month proposal with volume discount above 50 seats.
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
        \(openItemsBlock)

        Section rules for the real output:
        - **What needs attention**: \(attentionInstruction)
        - **Meeting-by-meeting**: one bullet per meeting in order. If a meeting has no "Last time" excerpt above, write exactly "First conversation — no prior context." for that bullet.
        - **Day-end goals**: two or three bullets, each tied to a meeting from the schedule.

        Begin your response with the literal line "## Today's read".
        """
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
}
