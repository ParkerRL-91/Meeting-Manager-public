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

    /// The Ollama model name to use for on-device summarization (e.g. "llama3.2:3b").
    var ollamaModel: String = OllamaService.defaultModel

    static let `default` = AppSettings(
        whisperModel: "large-v3",
        summaryPromptTemplate: DefaultPrompts.meetingSummary,
        claudeModel: "claude-sonnet-4-20250514",
        calendarSyncIntervalMinutes: 15,
        notificationLeadTimeMinutes: 2,
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
    }
}

// MARK: - Default Prompts

enum DefaultPrompts {
    static let meetingSummary = """
    You are a meeting assistant. Summarize the following meeting transcript and user notes into a structured summary.

    Meeting: {{meetingTitle}}
    Date: {{date}}
    Duration: {{duration}}

    ## Transcript:
    {{transcript}}

    ## User Notes:
    {{notes}}

    Please provide:
    1. **Key Discussion Points** - Main topics discussed
    2. **Decisions Made** - Any decisions or agreements reached
    3. **Action Items** - Tasks assigned with owners if mentioned
    4. **Follow-ups** - Items needing future attention
    """
}
