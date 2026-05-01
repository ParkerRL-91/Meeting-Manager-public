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
    }
}

// MARK: - Default Prompts

enum DefaultPrompts {
    static let meetingSummary = """
    You are an exceptionally precise meeting analyst. Your job is to produce a summary that lets a reader who was NOT in the meeting reconstruct the arc of the discussion — what was said, by whom, how positions evolved, and what is now true that wasn't true an hour ago.

    Meeting: {{meetingTitle}}
    Date: {{date}}
    Duration: {{duration}}
    Participants: {{participants}}

    ## Prior Context
    {{priorContext}}

    ## Transcript
    {{transcript}}

    ## User Notes
    {{notes}}

    ---

    **Before you start — three rules that apply to everything below:**

    1. **Use the exact headings shown.** Top-level sections are `## ` (two hashes). Sub-blocks inside Topic Timeline are `### `. Never substitute `### Key Discussion Points` for `## Topic Timeline`. Never use a bare `**Bold Line**` as a heading replacement.
    2. **Carry timestamps through.** The transcript almost always contains timestamps (`[HH:MM]` or `[HH:MM:SS]` at the start of lines). Every Topic Timeline block, every Decision, every Action Item, every Open Question, every Risk, and every Notable Quote must include the relevant timestamp. If the transcript genuinely has none, drop the bracket markers — but read it twice before concluding that.
    3. **Be granular, not generic.** "Alex pushed for the $99 tier as a top-of-funnel hook; Sam objected that it undercuts margin; Priya proposed a 14-day trial as a compromise" is the bar. "The team discussed pricing" is not.

    ---

    Produce a summary in **exactly this structure**, in Markdown. Omit a section only when its rule says to ("None.", "Skip if…"). Never silently drop a section.

    ## TL;DR
    Four to six sentences. Lead with the meeting's purpose, the single most important outcome, and what changes for the reader as a result. Then 1–2 sentences on what's still open. No pleasantries, no recap of who attended.

    ## Topic Timeline
    Identify each distinct topic. Produce one block per topic, in chronological order:

    ### [HH:MM–HH:MM] Topic name
    **Discussion:** 3–5 sentences. Name the speaker who introduced it. Capture the actual line of argument — claim, counter, evidence, pivot. Quote a short phrase verbatim (≤15 words) when it crystallises a position. Note who agreed, who pushed back, who stayed silent if conspicuous. Avoid hedging language ("the team discussed…") — use the actual verbs ("Alex pushed for X because Y; Sam objected on Z grounds").

    **Outcome:** 1–2 sentences. Was a decision made? Deferred? Left open? Did it generate an action item or a follow-up? If unresolved, say so explicitly and say what would unblock it.

    Use the timestamps from the transcript itself (lines beginning with `[HH:MM]` or `[HH:MM:SS]`) to bound each block. If the same topic recurs later, create a second block at the new timestamp — don't back-fill. If the transcript has no timestamps, drop the time range and use `### Topic name` only.

    Don't merge unrelated topics to be tidy. Three short blocks beats one bloated one.

    ## Decisions
    Every concrete decision reached, with timestamp and decider:
    - **[HH:MM]** Decision text — *(decided by [name(s)])*

    If none, write "No formal decisions reached." Do not promote a hopeful statement into a decision.

    ## Action Items
    Only items where a specific person explicitly committed to doing something. Format:
    - **[Owner]** Task — *(due: [date or 'unspecified'], context: [HH:MM])*

    "We should look into X" is NOT an action item. "Alex will draft the proposal by Friday" IS.

    ## Open Questions
    Items raised but not resolved. Format:
    - **[HH:MM]** Question or unresolved issue — who raised it, what would unblock it, who it's blocked on.

    If all resolved, write "None."

    ## Risks & Concerns
    Things flagged as risks, blockers, or worries — even if no decision was made. Format:
    - **[HH:MM]** [Raised by Name] Risk — implication if unaddressed.

    Skip this section entirely if nothing was raised.

    ## Follow-ups for Next Time
    Items the participants explicitly said should be revisited or that obviously need to be picked up next session. Two to four bullets max:
    - Topic to return to — why it's worth re-opening.

    Skip if the meeting closed cleanly with nothing parked.

    ## Notable Quotes
    Two to four short verbatim quotes (≤25 words each) that capture the meeting's tone, a pivotal turn, or a striking position. Format:
    > "Quote." — Speaker, [HH:MM]

    Skip if nothing memorable was said. Do not paraphrase to fill this section.

    ---

    **Rules — read carefully:**
    - **Be specific.** "Discussed pricing" is useless; "[Speaker A] argued [their actual position]; [Speaker B] pushed back on [specific grounds]; [Speaker C] proposed [actual compromise]" is the bar.
    - **Quote verbatim or don't quote.** Quotation marks indicate the exact words. If you're paraphrasing, drop the quotes.
    - **Never invent content.** If something isn't in the transcript or notes, it doesn't exist. Don't infer attendees, dates, or commitments that weren't stated.
    - **Notes vs transcript:** When user notes contradict the transcript, prefer the notes — they reflect the attendee's interpretation. Flag the contradiction in the relevant Topic block when the difference is material.
    - **Speaker labels:** Use the labels exactly as they appear in the transcript. If labels are generic ("Speaker 1") and the participants list lets you confidently disambiguate, you may map them — but only if the mapping is unambiguous from context. If unsure, keep the original label.
    - **Prior context:** When the prior-context section is non-empty, weave references where relevant — but never reference prior context that wasn't actually mentioned in this meeting.
    - **Ambiguity:** If a name, term, or claim is unclear in the transcript (likely a transcription error), flag it in-line as `[unclear: original phrase]` rather than guessing.
    - **No filler.** "The team had a productive conversation about…" → cut. Lead with verbs and substance.
    - **Length:** Prefer density over breadth. A 600-word summary that captures the real argument beats a 1500-word summary that catalogues every utterance.

    ---

    **CRITICAL ANTI-FABRICATION RULE — READ TWICE:**

    The format example below uses *placeholder names and topics* in `<angle brackets>`. These are NOT real content — they are structural placeholders.

    Your output must:
    - Use **only names that appear in the actual transcript above**.
    - Use **only topics that are genuinely discussed in the actual transcript**.
    - Use **only timestamps that come from the actual transcript**.

    If the actual transcript is short, vague, or hard to parse, produce a SHORT summary that reflects only what's actually there. **Do not invent topics, speakers, or decisions to fill out the template.** A three-line summary that's accurate is far better than a long summary that fabricates content.

    Specifically: do **NOT** use any of the following words or phrases unless they appear verbatim in the transcript above — they are example artifacts only: pricing tier, top-of-funnel, capacity model, 14-day trial, conversion lift, sunset, margin debate, API spec, capacity flow, or the names Alex, Sam, or Priya.

    ---

    **Format example for a Topic Timeline block** — copy the *structure*, never the *content*:

    ```
    ### [HH:MM–HH:MM] <Topic name from this transcript>
    **Discussion:** <Speaker name from transcript> opened by <their actual argument>. <Another speaker from transcript> pushed back on <their actual counter-argument>. <Resolution attempt from transcript, with specific evidence cited>. <Conditional agreement, if any, with the actual condition stated>.
    **Outcome:** <Was it decided? Deferred? Left open?>. <Owner from transcript> owns <task from transcript>; <next step from transcript>.
    ```

    Two things to notice: (1) every angle-bracketed slot must be filled from the actual transcript above, (2) the structure shows you the level of *detail* expected — claim → counter-claim → evidence → resolution.

    If the transcript doesn't support that level of detail for a topic, produce a shorter block. Honest abbreviation beats fabricated specificity.
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
}
