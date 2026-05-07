import Foundation

/// One candidate prompt: the system + user templates and a stable id used
/// by the report. The runner substitutes `{{transcript}}`,
/// `{{participants}}`, `{{meetingTitle}}`, `{{date}}` into both templates
/// before sending to the model.
struct Candidate {
    let id: String
    let systemPrompt: String
    let userPromptTemplate: String

    func userPrompt(for fixture: Fixture) -> String {
        userPromptTemplate
            .replacingOccurrences(of: "{{transcript}}", with: fixture.transcriptText)
            .replacingOccurrences(of: "{{participants}}", with: fixture.participants.joined(separator: ", "))
            .replacingOccurrences(of: "{{meetingTitle}}", with: fixture.title)
            .replacingOccurrences(of: "{{date}}", with: fixture.date)
    }
}

/// One prompt category — action-item, attribution, summary, outline.
/// The orchestrator iterates over each category's candidates.
enum PromptKind: String, CaseIterable {
    case actionItem  = "action-item"
    case attribution
    case summary
    case outline

    var candidates: [Candidate] {
        switch self {
        case .actionItem:  return ActionItemCandidates.all
        case .attribution: return AttributionCandidates.all
        case .summary:     return SummaryCandidates.all
        case .outline:     return OutlineCandidates.all
        }
    }
}

// MARK: - Action item candidates

enum ActionItemCandidates {
    static let baseline = Candidate(
        id: "baseline-current-prod",
        systemPrompt: "You are an expert at extracting action items from meeting transcripts. Reply with JSON only.",
        userPromptTemplate: """
        Extract action items from this meeting transcript:

        {{transcript}}

        Return a JSON array. Each item: {"title": string, "assignee": string|null, "due_date": string|null}.
        """
    )

    /// Tighter system prompt + JSON schema preamble + few-shot example.
    /// Hypothesis: explicit schema + worked example raises JSON validity
    /// rate on Qwen3 4B (where the baseline drifts on edge cases).
    static let schemaFirst = Candidate(
        id: "schema-first",
        systemPrompt: """
        You extract action items from meeting transcripts as a strict JSON array. \
        Respond with ONLY the JSON — no preamble, no Markdown code fences, no closing notes. \
        Every action item is a discrete commitment by a named person to do a specific thing. \
        If no action items exist, respond with the empty array `[]`.
        """,
        userPromptTemplate: """
        Schema:
        [
          {
            "title": "string — the action, in imperative form",
            "assignee": "string or null — the person committed to it, exactly as named in the transcript",
            "due_date": "string or null — natural-language date if stated; null otherwise"
          }
        ]

        Example input snippet:
        > **Sarah** _[1:14]_  Yeah, let's grab 10 minutes at 10:30. I'll send a calendar invite.

        Example output element:
        {"title": "Send calendar invite for 10:30 meeting", "assignee": "Sarah", "due_date": "today"}

        Now extract action items from the meeting below. Return the JSON array only.

        Meeting: {{meetingTitle}}
        Date: {{date}}
        Participants: {{participants}}

        Transcript:
        {{transcript}}
        """
    )

    /// Same content as schema-first but with the schema in the system
    /// prompt instead of the user prompt. Tests Qwen3's preference for
    /// instruction location.
    static let schemaInSystem = Candidate(
        id: "schema-in-system",
        systemPrompt: """
        You extract action items from meeting transcripts as a strict JSON array.

        Output schema:
        [
          {
            "title": "string — the action, imperative form",
            "assignee": "string or null — exact name from transcript",
            "due_date": "string or null — natural-language date if stated"
          }
        ]

        Rules:
        - Respond with ONLY the JSON array. No preamble, no Markdown, no explanation.
        - An action item is a discrete commitment by a named person to do a specific thing.
        - If no action items exist, respond with `[]`.
        - The assignee must be a name that appears in the transcript. Do not invent names.
        """,
        userPromptTemplate: """
        Meeting: {{meetingTitle}}
        Date: {{date}}
        Participants: {{participants}}

        Transcript:
        {{transcript}}

        Extract the action items as a JSON array. Output JSON only.
        """
    )

    static let all: [Candidate] = [baseline, schemaFirst, schemaInSystem]
}

// MARK: - Attribution candidates

enum AttributionCandidates {
    static let baseline = Candidate(
        id: "baseline-current-prod",
        systemPrompt: "You match anonymous speaker clusters to real attendee names. Reply with JSON only.",
        userPromptTemplate: """
        You are matching anonymous speaker clusters to real meeting attendees. Below are the attendees and the first turns from each unidentified speaker cluster (the user themselves is NOT in this list).

        Meeting attendees: [{{participants}}]

        For each speaker cluster, return the SINGLE most likely attendee, or "Unknown" if you cannot tell. Do not invent names not in the list.

        Speaker clusters:

        {{transcript}}

        Respond as a strict JSON object on a single line:
        {"Speaker 1": "Alex Chen", "Speaker 2": "Unknown"}
        """
    )

    /// Anti-hallucination emphasis + clear "Unknown vs guess" framing.
    static let strictUnknown = Candidate(
        id: "strict-unknown",
        systemPrompt: """
        You map anonymous speaker cluster ids ("Speaker 1", "Speaker 2", ...) to real attendee names from a fixed list. \
        You respond with ONLY a single-line JSON object. \
        The values you write MUST be either an exact name from the attendee list OR the literal string "Unknown". \
        You never invent names. When in doubt, write "Unknown" — that's a correct answer, not a failure.
        """,
        userPromptTemplate: """
        Meeting attendees (the only valid values for the JSON, besides "Unknown"):
        {{participants}}

        Speaker clusters and their first turns:

        {{transcript}}

        Output a single-line JSON object mapping each cluster id to either an exact attendee name from the list above, or "Unknown" if you cannot confidently identify them. JSON only — no preamble.
        """
    )

    /// Short and direct — minimal instructions, on the theory that Qwen3
    /// follows simple instructions cleanly without extra scaffolding.
    static let minimal = Candidate(
        id: "minimal",
        systemPrompt: "Map speaker cluster ids to attendee names. Use exact names from the attendee list, or \"Unknown\". Output JSON only.",
        userPromptTemplate: """
        Attendees: {{participants}}

        Clusters:
        {{transcript}}

        JSON:
        """
    )

    static let all: [Candidate] = [baseline, strictUnknown, minimal]
}

// MARK: - Summary candidates

enum SummaryCandidates {
    static let baseline = Candidate(
        id: "baseline-current-prod",
        systemPrompt: "You are a precise meeting analyst.",
        userPromptTemplate: """
        Summarize the following meeting in Markdown. Include sections for Key Discussion Points, Decisions, Action Items, and Open Questions. Cite who said what when relevant.

        Meeting: {{meetingTitle}}
        Date: {{date}}
        Participants: {{participants}}

        Transcript:
        {{transcript}}
        """
    )

    /// Tighter shape constraints + section minimums.
    static let structured = Candidate(
        id: "structured-sections",
        systemPrompt: """
        You produce a structured Markdown summary of a meeting transcript. \
        You ground every claim in the transcript and never invent decisions or facts. \
        You write in past tense. You begin DIRECTLY with the first ## header — no preamble.
        """,
        userPromptTemplate: """
        Output exactly these sections in this order. Skip a section ONLY if it would be empty.

        ## Key Discussion Points
        3–6 bullet points. Each starts with **Topic:** then a 1–2 sentence description with named people and specifics.

        ## Decisions
        Bullet list of decisions made. Each is a complete sentence with named decision-makers when known.

        ## Action Items
        Bullet list. Each: **Owner** — what they committed to, with date if stated.

        ## Open Questions
        Bullet list of questions raised but not resolved.

        Constraints:
        - No preamble. Begin with `## Key Discussion Points`.
        - No closing recap.
        - Every claim grounded in the transcript.
        - Use past tense for the prose.

        Meeting: {{meetingTitle}}
        Date: {{date}}
        Participants: {{participants}}

        Transcript:
        {{transcript}}
        """
    )

    /// Narrative-style summary that captures the arc, not just a structured list.
    static let arc = Candidate(
        id: "arc-narrative",
        systemPrompt: """
        You produce structured meeting summaries in Markdown. \
        Your goal: a reader who wasn't present can understand WHAT was discussed, \
        HOW positions evolved, WHAT was decided, and WHO owns what next. \
        Past tense, third person, grounded in transcript only. Begin DIRECTLY \
        with the first `## ` header — no preamble.
        """,
        userPromptTemplate: """
        Output Markdown sections. The first MUST be `## Summary` — a 2–4 sentence \
        opening paragraph capturing what happened in the meeting overall.

        Then output:

        ## Key Discussion Points
        3–6 bullets. **Topic name** — 1–2 sentences naming people and specifics.

        ## Decisions
        Bullets of explicit decisions. Skip the section if there were none.

        ## Action Items
        Bullets: **Owner** — committed action, with date if stated.

        ## Open Questions
        Bullets of questions raised but unresolved. Skip if none.

        Meeting: {{meetingTitle}}
        Date: {{date}}
        Participants: {{participants}}

        Transcript:
        {{transcript}}
        """
    )

    static let all: [Candidate] = [baseline, structured, arc]
}

// MARK: - Detailed outline candidates

enum OutlineCandidates {
    /// The current prod prompt — keep as the head-to-head baseline.
    static let baseline = Candidate(
        id: "baseline-current-prod",
        systemPrompt: """
        You produce detailed time-stamped meeting outlines as structured Markdown. Every section is `## [mm:ss – mm:ss] Topic Name` with a `**Speakers**:` line, a 3–6 sentence prose paragraph in past tense, and an optional bullet list of facts. You ground every claim in the provided transcript and never invent facts or names. You begin DIRECTLY with the first `## [...]` header — no preamble, no overview, no closing recap.
        """,
        userPromptTemplate: """
        Produce a detailed time-stamped outline of the meeting transcript below.

        Section format:
        ## [mm:ss – mm:ss] Topic Name
        **Speakers**: <names from transcript labels only>

        <4–7 sentence paragraph, MINIMUM 80 words, past tense>

        - Optional bullets — only for hard facts not already in prose

        Section length: AT LEAST 3 minutes per section. Group multiple turns on the same topic.

        Speakers: from transcript labels only — NEVER copy participants list.

        Coverage: cover the entire transcript end-to-end.

        Meeting: {{meetingTitle}}
        Date: {{date}}
        Participants (calendar context — DO NOT use as speakers list): {{participants}}

        Transcript:
        {{transcript}}
        """
    )

    /// Stronger anti-padding language + concrete example.
    static let antiPadding = Candidate(
        id: "anti-padding",
        systemPrompt: """
        You produce detailed time-stamped meeting outlines as structured Markdown. \
        Every section is `## [mm:ss – mm:ss] Topic Name` with a `**Speakers**:` line, \
        a substantive 4–7 sentence prose paragraph in past tense, and optional fact bullets. \
        You ground every claim in the transcript and never invent facts. You begin DIRECTLY \
        with the first `## [...]` header — no preamble. You write specific prose with named \
        people, named products, dates, and numbers — NEVER generic filler.
        """,
        userPromptTemplate: """
        Produce a detailed time-stamped outline of the meeting transcript below.

        ## Section format
        ## [mm:ss – mm:ss] Topic Name
        **Speakers**: <names from transcript labels only>

        <4–7 sentences, MINIMUM 80 words, past tense, with named specifics>

        - Optional bullets — only for hard facts not already in prose

        ## Length rule
        Each section spans AT LEAST 3 minutes; typical sections span 5–10. A 60-min meeting has 6–12 sections. NOT 30+.

        ## Speakers rule
        From transcript labels (the bold names before each turn). NEVER copy the participants list.

        ## Coverage rule
        Cover the ENTIRE transcript. The final section's end timestamp must match the last transcript timestamp.

        ## Avoid these filler patterns (CRITICAL)
        Do NOT write generic phrases like:
        - "emphasized the importance of building connections"
        - "discussed the various opportunities"
        - "would be working with several companies"
        - "highlighted the importance of attending"

        If you find yourself writing one of these, replace it with the actual specifics. WHICH connections, WHICH events by name, WHAT exactly was said.

        ## Concrete example (illustrative — do not copy content)

        ## [12:18 – 19:42] Regeneron Site Visit Logistics
        **Speakers**: Ruby Zhao, Bill, Sarah Chen

        Bill walked through the Wednesday-morning Regeneron visit, noting that the delegation would meet with Aris Baras and three RGC clinical-applications staff between 9:00 and 11:30 AM. Ruby Zhao confirmed badges had been issued and that the buses leave the hotel at 8:15 AM sharp. Sarah Chen asked whether her co-founder, joining mid-week, could attend; Bill said yes provided she registered through the portal by Friday. The Regeneron team requested two-minute company intros at the start of the session.

        - Buses depart 8:15 AM from hotel; photo ID required
        - Two-minute intro requested at session start — single slide

        ---

        Meeting: {{meetingTitle}}
        Date: {{date}}
        Participants (calendar context — DO NOT use as speakers list): {{participants}}

        Transcript:
        {{transcript}}

        Now produce the outline. Cover end-to-end. 6–12 sections.
        """
    )

    static let all: [Candidate] = [baseline, antiPadding]
}
