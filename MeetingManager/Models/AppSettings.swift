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

    /// The Google Calendar ID to sync. nil = use the primary calendar.
    var selectedCalendarId: String? = nil

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
    }
}

// MARK: - Default Prompts

enum DefaultPrompts {
    static let meetingSummary = """
    You are an exceptionally precise meeting analyst. Your job is to produce a summary that lets the reader understand exactly how the conversation progressed — not just what was decided, but how the group arrived there. The reader was not in the meeting and should be able to reconstruct the arc of the discussion from your output alone.

    Meeting: {{meetingTitle}}
    Date: {{date}}
    Duration: {{duration}}

    ## Transcript:
    {{transcript}}

    ## User Notes:
    {{notes}}

    ---

    Produce a summary in **exactly this structure**, in Markdown:

    ## TL;DR
    Three to five sentences. State the meeting's purpose, the most important outcomes, and the one thing the reader most needs to know. Lead with substance, not pleasantries.

    ## Topic Timeline
    Identify each distinct topic that was discussed. For each topic produce a block in this format — and timestamp every block:

    ### [HH:MM–HH:MM] Topic name
    **Discussion:** Two to four sentences capturing what was actually said. Name the speaker who introduced the topic. Note any disagreement, pivot, or change of mind. Quote a short phrase verbatim when it crystallises a position. Avoid hedging language ("the team discussed…") — be concrete about what was said.

    **Outcome:** One or two sentences. Was a decision made? Was it deferred? Was it left open? Did it generate an action item? If unresolved, say so explicitly.

    Use the timestamps from the transcript itself (lines beginning with `[HH:MM]` or `[HH:MM:SS]`) to set the start of each block. Set the end timestamp at the moment the conversation moved to the next topic. If the transcript has no timestamps, omit the time range and label blocks `### Topic name` instead — but still produce the Discussion / Outcome split.

    Order blocks chronologically. Do not merge unrelated topics. If the same topic recurs later in the meeting, create a second block at the new timestamp rather than back-filling the first.

    ## Decisions
    A bulleted list of every concrete decision, with the timestamp it was reached and the person/people who made it:
    - **[HH:MM]** Decision text — *(decided by [name(s)])*

    If no decisions were made, write "No formal decisions reached." Do not invent decisions.

    ## Action Items
    A bulleted list. Format each as:
    - **[Owner]** Task — *(due: [date or 'unspecified'], context: [HH:MM])*

    Only include items where someone explicitly committed to doing something. Do not list general aspirations as action items.

    ## Open Questions
    Items that were raised but not resolved. Bullet list with timestamps:
    - **[HH:MM]** Question or unresolved issue — who raised it, what would unblock it.

    If everything was resolved, write "None."

    ## Notable Quotes
    Two to four short verbatim quotes (≤25 words each) that capture the meeting's tone or pivotal moments. Format:
    > "Quote." — Speaker, [HH:MM]

    Skip this section if nothing memorable was said.

    ---

    **Rules:**
    - Be specific. "Discussed pricing" is useless; "Alex argued the $99 tier was undercutting margin while Sam pushed for it as a top-of-funnel hook" is useful.
    - Do not invent content not present in the transcript or notes.
    - If the user's notes contradict the transcript, prefer the notes — they reflect the meeting attendee's interpretation. Briefly flag the contradiction in the relevant Topic block if the difference is meaningful.
    - Use the speaker labels exactly as they appear in the transcript.
    - Keep prose tight. No filler ("the team had a productive conversation about…"). Lead with verbs.
    """
}
