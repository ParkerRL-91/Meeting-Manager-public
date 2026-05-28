import Foundation
import GRDB

struct AppSettings: Codable, Equatable {
    var id: Int64 = 1
    var whisperModel: String
    var summaryPromptTemplate: String
    var claudeModel: String
    var calendarSyncIntervalMinutes: Int
    var notificationLeadTimeMinutes: Int
    var launchAtLogin: Bool
    var theme: String
    var aiEnabled: Bool = false

    /// When true, automatically start recording when a call app or browser meeting is detected.
    var autoRecord: Bool = false

    /// When true, show a notification suggesting to record when a meeting is detected.
    /// Ignored if autoRecord is true (auto-record takes precedence).
    var autoInvite: Bool = true

    /// Legacy single-Google-calendar selection. Read as a fallback when
    /// `selectedGoogleCalendarIds` is empty. New code should write to the
    /// multi-select field instead.
    var selectedCalendarId: String? = nil

    /// Comma-separated list of Google calendar IDs to sync. Empty/nil = fall
    /// back to `selectedCalendarId` (or "primary" if that's also unset).
    /// Stored as a comma-separated string rather than JSON for migration
    /// simplicity — Google calendar IDs never contain commas.
    var selectedGoogleCalendarIds: String? = nil

    /// Comma-separated list of `EKCalendar.calendarIdentifier`s to include
    /// in Apple Calendar sync. Empty/nil = include all readable calendars.
    /// Apple calendar identifiers are UUIDs and never contain commas.
    var selectedAppleCalendarIds: String? = nil

    /// When true, meeting summaries are generated on-device using a local LLM instead of the Claude API.
    var useLocalLLM: Bool = false

    /// The Ollama model name to use for on-device summarization.
    /// `"auto"` enables adaptive selection — picks the best model for each transcript's size.
    /// `"llama3.2:3b"` forces the 3B model only (recommended for slower Macs).
    var ollamaModel: String = "auto"

    /// When true, automatically generate a summary ~10 minutes after transcription completes.
    var autoGenerateSummary: Bool = false

    /// The recipe ID to use for auto-generated summaries. nil = use the default meeting summary prompt.
    var defaultRecipeId: String? = nil

    /// When true, automatically enqueue a follow-up email recipe after a summary is generated.
    var autoFollowUpEmail: Bool = false

    /// When true, schedule a daily morning briefing notification.
    var morningBriefEnabled: Bool = false

    /// Hour (0-23) for the morning briefing notification.
    var morningBriefHour: Int = 8

    /// Minute (0-59) for the morning briefing notification.
    var morningBriefMinute: Int = 30

    /// When true, automatically write meeting summaries and transcripts back to
    /// the Knowledge Base folder after a summary is generated.
    /// Files are written as Markdown under <KB root>/Meeting Notes/YYYY/MM-Month/DD/Title.md
    var kbWriteBack: Bool = false

    /// When true, import contacts from macOS Contacts to improve speaker ID.
    /// Requires Contacts permission. Imported contacts create Person records
    /// but do NOT store contact details beyond name and email address.
    var contactsImportEnabled: Bool = false

    /// Prompt template for the detailed-outline pass. nil → fall back to
    /// `DefaultPrompts.detailedOutline`. Stored as nullable so the column
    /// can be added by migration without backfill — readers resolve nil to
    /// the default at use time. Edited via Settings → Prompts → Detailed Outline.
    var detailedOutlinePromptTemplate: String? = nil

    // MARK: - Integrated Profile Prep (Apollo)

    /// User-facing toggle for surfacing attendee profile cards (title,
    /// employment, LinkedIn) in the meeting view and pre-meeting prep.
    /// The cards only render when this is on, an Apollo API key is in
    /// the Keychain, and `apolloKeyValidated` is true — see ApolloService.
    var apolloProfilePrepEnabled: Bool = false

    /// Set to true after the Test button confirms the keychain's Apollo
    /// API key works. Cleared when the key changes. Drives whether the
    /// Attendee Profile section is allowed to surface.
    var apolloKeyValidated: Bool = false

    /// When the user last successfully ran the Test button. Surfaced in
    /// Settings as a "Last verified" timestamp.
    var apolloKeyLastValidatedAt: Date? = nil

    static let `default` = AppSettings(
        whisperModel: WhisperModel.largev3turbo.rawValue,
        summaryPromptTemplate: DefaultPrompts.meetingSummary,
        claudeModel: "claude-sonnet-4-20250514",
        calendarSyncIntervalMinutes: 15,
        notificationLeadTimeMinutes: 5,
        launchAtLogin: false,
        theme: "dark"
    )
}

// MARK: - GRDB

extension AppSettings: FetchableRecord, PersistableRecord {
    static let databaseTableName = "appSettings"

    enum Columns: String, ColumnExpression {
        case id, whisperModel, summaryPromptTemplate, claudeModel
        case calendarSyncIntervalMinutes, notificationLeadTimeMinutes
        case launchAtLogin, theme, aiEnabled, autoRecord, autoInvite, selectedCalendarId
        case useLocalLLM, ollamaModel
        case autoGenerateSummary, defaultRecipeId
        case autoFollowUpEmail
        case morningBriefEnabled, morningBriefHour, morningBriefMinute
        case kbWriteBack
        case selectedGoogleCalendarIds, selectedAppleCalendarIds
        case contactsImportEnabled
        case detailedOutlinePromptTemplate
        case apolloProfilePrepEnabled
        case apolloKeyValidated
        case apolloKeyLastValidatedAt
    }
}

// MARK: - Default Prompts

enum DefaultPrompts {
    static let meetingSummary = """
    You are a meeting analyst writing a summary for a person who was not in the meeting. Write the way a thoughtful colleague would write — clear sentences, named people, no spreadsheets.

    Meeting: {{meetingTitle}}
    Date: {{date}}
    Participants: {{participants}}

    ## Prior Context
    {{priorContext}}

    ## Transcript
    {{transcript}}

    ## User Notes
    {{notes}}

    ---

    Output Markdown using EXACTLY these section headings and the formatting rules below. Use `## ` (two hashes) for every heading. Skip a section only when its rule says to.

    ## TL;DR
    Three to five sentences as a single paragraph. Cover the purpose of the meeting, the most important outcome, and what is still open. No bullet list, no headings inside this section.

    ## Key Discussion Points
    Four to seven bullets, one per topic actually discussed. Each bullet uses this exact shape — bold topic name, an em-dash, then a 1–2 sentence description that names specific people, products, numbers, and dates from the transcript:

    - **Topic name** — Description of what was discussed and how positions emerged. Name the people who spoke and what they said.

    Skip topics that are only mentioned in passing. Be specific: "Alice argued the pricing tier should sit at 99 dollars to match the competitor; Bob pushed back that this undercuts margin" beats "the team discussed pricing".

    ## Decisions
    One bullet per concrete decision. Each bullet starts with **bold the decision in one phrase**, then an em-dash, then the explanation including who decided:

    - **Decision in a phrase** — Explanation including the person or people who decided.

    If the meeting reached no formal decisions, write the single line: `- No formal decisions reached.`

    ## Action Items
    One bullet per commitment a named person explicitly took on. Each bullet starts with **bold the owner's name**, em-dash, then the action and any due date:

    - **Owner Name** — what they committed to do, by [when, if stated].

    If no one committed to anything, write: `- No action items captured.` "We should look into X" is not an action item. "Alice will draft the proposal by Friday" is.

    ## Open Questions
    One bullet per unresolved question, using the same shape:

    - **Question in a phrase** — context, who raised it, what would unblock it.

    Skip the section entirely if everything got resolved.

    ## Notable Quotes
    Optional. Up to three short verbatim quotes that capture a turn in the conversation:

    > "Quote." — Speaker name

    Skip the section if nothing memorable was said.

    ---

    Format rules (these matter — earlier outputs broke the UI):

    - **Bullets only — no Markdown tables.** Never write `| Column | Column |` rows or `|---|---|` separator lines. The renderer is expecting bullets.
    - **No HTML tags.** No `<br>`, no `<p>`, no `&nbsp;`, no escape sequences. Use plain Markdown line breaks.
    - **No "Status: Pending / Completed" columns.** Action items are commitments; their state lives elsewhere in the app.
    - **No timestamp brackets in this summary.** Don't write `[HH:MM]` or `[0:23]` in the discussion points, decisions, or action items. The detailed outline tab covers timestamping; this summary is the human-readable digest.
    - **Bold the entity in every bullet.** The first phrase of every Key Discussion / Decision / Action Item / Open Question bullet is wrapped in `**`. The renderer uses this to lay out cards.
    - **Past tense.** The meeting is over.
    - **Section order: TL;DR → Key Discussion Points → Decisions → Action Items → Open Questions → Notable Quotes.** Don't number the headings (no `## 1. Key Discussion Points`).

    Anti-fabrication:

    - Use only names that appear in the transcript or participant list.
    - Use only topics genuinely discussed in the transcript.
    - If the transcript is sparse, produce a sparse summary. Three honest bullets beat ten invented ones.
    - When user notes contradict the transcript, prefer the notes — they reflect the attendee's interpretation.
    """

    /// Pre-meeting context brief. Synthesises a focused, actionable one-page brief
    /// for the user before a meeting starts, drawing on prior meeting summaries,
    /// open commitments, notes from related sessions, and participant history.
    ///
    /// Variables:
    /// - {{meetingTitle}}, {{date}}, {{participants}}, {{userNotes}}
    /// - {{relatedMeetings}}: bullet list of prior related meetings with title, date, summary excerpt
    /// - {{openActionItems}}: bullet list of open commitments owned by these participants
    /// - {{priorNotes}}: relevant snippets from notes taken in past meetings with these participants/topics
    static let preMeetingBrief = """
    You are a chief-of-staff briefing your principal for a meeting that starts in the next few minutes. Your job is to make sure they walk in already informed — not narrating history, but pre-loading the context so the meeting can start at minute one instead of minute fifteen.

    Tone: precise, direct, written for a busy reader. No throat-clearing. Markdown formatting, but lean. Treat every word as expensive.

    ## Upcoming Meeting
    Title: {{meetingTitle}}
    When: {{date}}
    Participants: {{participants}}

    ## What the user wrote ahead of time
    {{userNotes}}

    ## Related prior meetings (most relevant first)
    {{relatedMeetings}}

    ## Open commitments owned by these participants
    {{openActionItems}}

    ## Relevant notes from past meetings
    {{priorNotes}}

    ## Relevant excerpts from the user's Knowledge Base
    These are excerpts retrieved from the user's own document folder (not from prior meetings). Treat them as authoritative reference material — internal docs, OKRs, project briefs, etc. Cite the source path when you use them.
    {{knowledgeBase}}

    ---

    Produce the brief in **exactly this structure**. Skip a section if its rule says to. Do not add sections.

    ## Why this meeting exists
    One or two sentences. State the apparent purpose based on title, participants, and prior context. If you can't tell from the inputs, say so plainly: "Purpose unclear from available context — likely [best guess] given [signal]."

    ## What the user should already know walking in
    Three to six bullets of substantive context — *not* a recap of every prior meeting. Each bullet is one fact or position the user needs loaded into working memory. Bullets should follow this *shape* (placeholders only — fill from the actual inputs above):
    - "<Person from inputs> previously pushed back on <topic from inputs>; expect them to raise <related concern> again."
    - "<Topic from inputs> was deferred pending <blocker from inputs> — that's still outstanding."
    - "<Person from inputs> committed to <task from inputs> by <date> — worth checking whether it landed."

    Bad bullets to avoid: anything that just summarises a prior meeting without tying it to *this one*. If a prior meeting isn't actually relevant, leave it out — quality over coverage. Never use the names Alex, Sam, or Priya, the topic "$99 tier", or any of the placeholder phrases above unless they appear verbatim in the inputs.

    ## Likely discussion points
    Two to four bullets predicting what will come up, ranked by likelihood. Anchor each prediction in evidence from the inputs. Format:
    - **[Topic]** — *Likely because:* short reason rooted in prior meetings, open items, or notes.

    If the inputs don't support a prediction, write "Insufficient prior context to predict topics confidently."

    ## Open commitments to surface
    Pull the items from `Open commitments` that are most relevant to this meeting's likely scope. Format:
    - **[Owner]** Commitment — *(promised: [when]; context: [meeting title or date])*

    Lead with items owned by participants in this meeting. Skip the section entirely if there are no relevant open items.

    ## Questions worth asking
    Two to four sharp questions the user could open with or hold in reserve. Each question should advance the meeting — not generic ("any updates?") but specific to the situation. Shape (fill from actual inputs):
    - "Is <specific deliverable from inputs> ready, or do we need a different unblock path?"
    - "Did <specific issue from inputs> ever get resolved, or are we still parked?"

    If you don't have enough context for sharp questions, write "Insufficient context for targeted questions — start with a status round-robin."

    ## One-line readiness summary
    A single italicised line capturing the user's footing as they walk in. Shape (do NOT copy the literal example wording — substitute from the actual inputs):
    > *<One sentence describing how prepared the user is, drawn from the actual inputs>.*
    > *Limited prior context; treat this as a discovery conversation.*  ← use this verbatim only when prior context is genuinely empty.

    ---

    **Rules:**
    - **Don't recap past meetings.** This is a brief, not a digest. Every line earns its place by being useful for the next 60 minutes.
    - **No invented facts.** If a name, commitment, or decision isn't in the inputs, it doesn't exist. Don't fill gaps with plausible fabrication.
    - **Prefer silence to noise.** A short brief that's all signal beats a long brief padded with low-relevance context.
    - **Cite when concrete.** When a fact comes from a specific prior meeting or note, name the source briefly: "(per Mar 12 sync)", "(from your notes)". Don't over-cite — only when it changes how the user weighs the fact.
    - **Don't address the user.** Write in third person about the participants and the situation. The user reads this — they don't need to be told what they wrote.
    - **Length budget:** Aim for 200–400 words total. Hard ceiling: 500.
    """

    // MARK: - Detailed Outline (v3.10.3+)

    /// The detailed-outline prompt produces a time-stamped, topic-segmented
    /// readable record of the meeting. Goal density: between the one-page
    /// summary and the full transcript. Used by `DetailedOutlineService`.
    ///
    /// Editable via Settings → Prompts → "Detailed Outline" — the value
    /// lives on `appSettings.detailedOutlinePromptTemplate`. nil/empty
    /// falls back to this default at call time.
    static let detailedOutline = """
    You are producing a detailed time-stamped outline of a meeting. Output ONLY structured Markdown — no preamble, no closing notes, no overall recap.

    For each major topic discussed, output one section in this exact shape:

    ## [mm:ss – mm:ss] Topic Name
    **Speakers**: <comma-separated names of people who actually spoke during this section>

    <A 3–6 sentence paragraph in past tense describing what was said and how the conversation evolved during this segment. Name people by name. Capture the arc: who raised the topic, how others responded, where positions diverged or aligned, what was decided or left open. Quote specific terms, product names, dates, numbers, and named artifacts (decks, docs, tickets) when they appear. Capture disagreements explicitly — this is where the value is.>

    - Optional bullet list of hard facts surfaced in this section: numbers cited, dates committed to, decisions made, open questions, named artifacts. Skip the list if the prose covers everything.

    ### How to identify topic sections

    A topic section covers one sustained subject of conversation. Multiple speakers debating the same subject is ONE section, not one section per speaker. A brief tangent or aside that gets dropped belongs in the surrounding section, not its own.

    Typical section durations by meeting length:
    - Meetings under 10 minutes: 1–3 sections. A single-section outline is acceptable for a brief standup.
    - Meetings 10–60 minutes: 4–10 sections, each spanning roughly 3–15 minutes of conversation.
    - Meetings over 60 minutes: up to 1 section per 5–8 minutes of content, to a maximum of 20 sections.

    Sections should generally span at least 2 minutes. Preserve shorter sections only when they contain a key decision, announcement, or action item that would lose clarity if merged into an adjacent topic.

    If a topic is revisited after a gap of more than 5 minutes of unrelated discussion, create a separate section for each occurrence. Add "(continued)" to the topic name for the later occurrence.

    Always err toward fewer, denser sections rather than many short ones.

    ### Format requirements

    - Topic name: a 2–6 word concrete noun phrase. "Q3 hiring plan" — not "Discussion".
    - Timestamps: `mm:ss` for meetings under 1 hour, `h:mm:ss` for longer. Use timestamps from the transcript verbatim.
    - Section ranges should be contiguous: each section's end timestamp matches the next section's start. No gaps, no overlaps.
    - Speaker names: exactly as they appear in the transcript. No titles, no normalization.
    - When many speakers discuss the same topic, group them into one section rather than splitting by speaker.
    - If speaker names are unavailable for a segment, describe contributions by content rather than attribution.

    ### Constraints

    - Begin DIRECTLY with the first `## [...]` header. No preamble like "Here is the outline" or "## Meeting Overview".
    - End with the last section's content. No "## Conclusion" or recap section.
    - Every factual claim must be grounded in the transcript. No inferred motivations, no plausible-sounding fabrications.
    - Past tense throughout the prose paragraphs. The meeting is over.
    - Third person about the participants. Don't address the reader.
    - Don't include the meeting title in the output — the UI already shows it.

    Meeting: {{meetingTitle}}
    Date: {{date}}
    Participants: {{participants}}

    Transcript:
    {{transcript}}

    Now produce the detailed outline.
    """
}
