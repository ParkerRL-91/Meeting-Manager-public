import Foundation

/// Pure, `nonisolated` assembly of the "Enhance Notes" system + user prompts.
///
/// Factored out of `AppState.generateEnhancedNotesForTask` so the invariants
/// that matter — the structure-preserving instruction survives, the
/// anti-hallucination rules are present, and an absent transcript switches the
/// pass into "polish only, no factual additions" — are unit-testable without
/// standing up `AppState`, a database, or an AI backend.
///
/// The template (`DefaultPrompts.enhanceNotes` by default, or the user's
/// `appSettings.enhanceNotesPromptTemplate`) already carries the bulk of the
/// guidance. This builder substitutes the meeting variables, injects the
/// transcript-or-placeholder, and appends a short system prompt that hardens
/// the no-fabrication contract for smaller local models.
enum EnhanceNotesPromptBuilder {

    /// Placeholder substituted for `{{transcript}}` when no transcript exists
    /// (the live-meeting case — the app transcribes only after stop). Its
    /// presence is what flips the pass into "polish only".
    static let noTranscriptPlaceholder = "(no transcript available)"

    struct Prompts: Equatable {
        let system: String
        let user: String
    }

    /// Build the prompts for one enhancement pass.
    ///
    /// - Parameters:
    ///   - template: the resolved prompt template (custom or default).
    ///   - meeting: source of `{{meetingTitle}}`, `{{date}}`, `{{participants}}`.
    ///   - notes: the user's combined raw notes — the ground truth.
    ///   - transcript: the meeting transcript, or empty for a live/notes-only
    ///     polish. Empty input substitutes `noTranscriptPlaceholder`.
    static func build(
        template: String,
        meeting: Meeting,
        notes: String,
        transcript: String
    ) -> Prompts {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTranscript = !trimmedTranscript.isEmpty
        let transcriptValue = hasTranscript ? trimmedTranscript : noTranscriptPlaceholder

        let participants = meeting.participantList.isEmpty
            ? "Not recorded"
            : meeting.participantList.joined(separator: ", ")

        let dateString: String = {
            if let start = meeting.startDate ?? meeting.scheduledStartDate {
                return start.formatted(date: .long, time: .shortened)
            }
            return "Unknown date"
        }()

        let user = template
            .replacingOccurrences(of: "{{meetingTitle}}", with: meeting.title)
            .replacingOccurrences(of: "{{date}}", with: dateString)
            .replacingOccurrences(of: "{{participants}}", with: participants)
            .replacingOccurrences(of: "{{notes}}", with: notes)
            .replacingOccurrences(of: "{{transcript}}", with: transcriptValue)

        // System prompt reinforces the two rules smaller models drift on most:
        // mirror the user's structure (don't impose a summary format), and add
        // no facts. The transcript-present vs absent branch is deliberate —
        // when there's no transcript there is nothing to "correct from", so the
        // contract narrows to pure polish.
        let base = """
        You are a careful editor polishing a person's own meeting notes. You preserve the \
        user's structure — their headings, their order, their emphasis — and you never \
        reshape the notes into a TL;DR / Decisions / Action Items summary format. You \
        expand terse fragments into complete sentences and fix grammar, but you do not \
        invent sections, decisions, action items, participants, names, figures, or quotes \
        that the user did not write. Output ONLY the polished notes as Markdown, with no \
        preamble and no closing commentary.
        """

        let system: String
        if hasTranscript {
            system = base + """


            A transcript is provided. Use it ONLY to correct names, dates, figures, and \
            product or company terms the user abbreviated or got slightly wrong, and to \
            complete a detail the user clearly began but left unfinished. The user's notes \
            remain the source of structure and emphasis; the transcript settles facts, not \
            format. Never contradict an intentional note.
            """
        } else {
            system = base + """


            No transcript is available (this is a live polish). Make NO factual additions \
            whatsoever — confine yourself to grammar, spelling, clarity, and sentence \
            completion of what the user already wrote. Do not infer or supply any detail \
            that is not already present in the notes.
            """
        }

        return Prompts(system: system, user: user)
    }
}
