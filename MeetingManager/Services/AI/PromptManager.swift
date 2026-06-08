import Foundation
import os

/// Manages prompt templates for AI summarization, including loading, saving,
/// and variable substitution.
final class PromptManager {

    // MARK: - Available Template Variables

    /// The placeholder tokens that can be used inside a prompt template.
    static let availableVariables: [(token: String, description: String)] = [
        ("{{meetingTitle}}", "Title of the meeting"),
        ("{{date}}", "Date the meeting took place"),
        ("{{duration}}", "Formatted duration (e.g. \"45 min\")"),
        ("{{participants}}", "Comma-separated participant names"),
        ("{{priorContext}}", "Brief context from prior related meetings (auto-populated)"),
        ("{{knowledgeBase}}", "Relevant excerpts from your Knowledge Base folder (auto-populated)"),
        ("{{transcript}}", "Full meeting transcript"),
        ("{{notes}}", "User-created notes"),
    ]

    // MARK: - Template Persistence

    /// Loads the current prompt template, falling back to the built-in default
    /// when the stored value is empty.
    ///
    /// Reads fresh from the database rather than the in-memory `appState.settings`
    /// snapshot — that snapshot can be stale after a save (the DB write doesn't
    /// invalidate it), so reading from settings caused saved edits to "revert"
    /// the next time PromptConfigView opened. The settings table is a single
    /// row and this is only called from the settings UI, so the read cost is
    /// negligible.
    func loadTemplate(settings: AppSettings = .default) -> String {
        let stored: String = {
            // Try fresh-from-DB first; fall back to the passed-in snapshot if
            // the DB read fails (offline / disk full / brand-new install).
            if let fresh = try? AppDatabase.shared.writer.read({ db in
                try AppSettings.fetchOne(db)?.summaryPromptTemplate
            }) {
                return fresh ?? settings.summaryPromptTemplate
            }
            return settings.summaryPromptTemplate
        }()
        return stored.isEmpty ? DefaultPrompts.meetingSummary : stored
    }

    /// Persists a custom prompt template. Pass an empty string to effectively
    /// revert to the default on next load. Also posts a notification so any
    /// observer of in-memory settings can refresh.
    func saveTemplate(_ template: String) {
        do {
            try AppDatabase.shared.writer.write { db in
                if var settings = try AppSettings.fetchOne(db) {
                    settings.summaryPromptTemplate = template
                    try settings.update(db)
                } else {
                    var settings = AppSettings.default
                    settings.summaryPromptTemplate = template
                    try settings.insert(db)
                }
            }
            Logger.ai.info("Prompt template saved (\(template.count) characters)")
            // Notify observers (AppState, etc.) so any cached in-memory copy
            // gets refreshed instead of returning stale data on the next read.
            NotificationCenter.default.post(name: .summaryPromptTemplateDidChange, object: nil)
        } catch {
            Logger.ai.error("Failed to save prompt template: \(error.localizedDescription)")
        }
    }

    // MARK: - Enhance-Notes Template Persistence

    /// Loads the "Enhance Notes" prompt template, falling back to the built-in
    /// default when the stored value is empty/nil. Reads fresh from the DB for
    /// the same reason `loadTemplate` does — the in-memory settings snapshot
    /// can be stale right after a save, which made edits appear to revert.
    func loadEnhanceTemplate(settings: AppSettings = .default) -> String {
        let stored: String? = {
            if let fresh = try? AppDatabase.shared.writer.read({ db in
                try AppSettings.fetchOne(db)?.enhanceNotesPromptTemplate
            }) {
                return fresh ?? settings.enhanceNotesPromptTemplate
            }
            return settings.enhanceNotesPromptTemplate
        }()
        let value = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? DefaultPrompts.enhanceNotes : value
    }

    /// Persists a custom "Enhance Notes" prompt template. Pass an empty string
    /// to revert to the default on next load. Posts the shared prompt-change
    /// notification so AppState refreshes its in-memory settings snapshot.
    func saveEnhanceTemplate(_ template: String) {
        do {
            try AppDatabase.shared.writer.write { db in
                if var settings = try AppSettings.fetchOne(db) {
                    settings.enhanceNotesPromptTemplate = template
                    try settings.update(db)
                } else {
                    var settings = AppSettings.default
                    settings.enhanceNotesPromptTemplate = template
                    try settings.insert(db)
                }
            }
            Logger.ai.info("Enhance-notes prompt template saved (\(template.count) characters)")
            NotificationCenter.default.post(name: .summaryPromptTemplateDidChange, object: nil)
        } catch {
            Logger.ai.error("Failed to save enhance-notes prompt template: \(error.localizedDescription)")
        }
    }

    // MARK: - Variable Substitution

    /// Replaces template placeholders with concrete meeting data.
    ///
    /// - Parameters:
    ///   - template: The raw prompt template containing `{{…}}` placeholders.
    ///   - meeting: The meeting whose metadata is injected.
    ///   - transcript: The full transcript text.
    ///   - notes: The combined user notes text.
    /// - Returns: A ready-to-send prompt string with all placeholders filled in.
    func substituteVariables(
        template: String,
        meeting: Meeting,
        transcript: String,
        notes: String,
        priorContext: String = "",
        knowledgeBase: String = ""
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short

        let dateString: String
        if let start = meeting.startDate ?? meeting.scheduledStartDate {
            dateString = dateFormatter.string(from: start)
        } else {
            dateString = "Unknown date"
        }

        let participantsString: String = {
            let list = meeting.participantList
            return list.isEmpty ? "Not recorded" : list.joined(separator: ", ")
        }()

        let priorContextString = priorContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No prior related meetings on file."
            : priorContext

        let knowledgeBaseString = knowledgeBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No Knowledge Base configured."
            : knowledgeBase

        var result = template
        result = result.replacingOccurrences(of: "{{meetingTitle}}", with: meeting.title)
        result = result.replacingOccurrences(of: "{{date}}", with: dateString)
        result = result.replacingOccurrences(of: "{{duration}}", with: meeting.formattedDuration)
        result = result.replacingOccurrences(of: "{{participants}}", with: participantsString)
        result = result.replacingOccurrences(of: "{{priorContext}}", with: priorContextString)
        result = result.replacingOccurrences(of: "{{knowledgeBase}}", with: knowledgeBaseString)
        result = result.replacingOccurrences(of: "{{transcript}}", with: transcript)
        result = result.replacingOccurrences(of: "{{notes}}", with: notes)

        return result
    }

    // MARK: - Preview Helpers

    /// Returns a sample-substituted prompt for UI preview purposes.
    func previewSubstitution(template: String) -> String {
        let sampleMeeting = Meeting(
            title: "Sprint Planning",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date(),
            status: .complete
        )
        return substituteVariables(
            template: template,
            meeting: sampleMeeting,
            transcript: "[00:00] Alice: Let's discuss the roadmap.\n[00:15] Bob: Sounds good.",
            notes: "Need to finalize Q3 priorities."
        )
    }
}
