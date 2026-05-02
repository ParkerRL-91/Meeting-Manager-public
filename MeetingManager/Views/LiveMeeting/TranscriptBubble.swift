import SwiftUI

/// A single transcript segment row showing timestamp, speaker, and text.
///
/// When `onRename` is supplied (v3.1 Layer 3, currently from
/// `FullTranscriptView`) the speaker label becomes a click-target menu —
/// pick from the meeting participants, "Mark as Unknown", or "Add custom…".
/// When nil (live recording bubbles) the label renders as plain text.
struct TranscriptBubble: View {
    let transcript: Transcript
    var meeting: Meeting? = nil
    /// When set, signals which menu action the user picked. The hosting
    /// view performs the rename + persistence + alias upsert.
    var onRename: ((TranscriptBubbleRenameAction) -> Void)? = nil
    /// When true, the speaker label renders italic + with a sparkles glyph
    /// to hint that the name was assigned by the LLM and not yet confirmed.
    var isAIAttributed: Bool = false
    /// v3.10 #2: confidence in [0, 1] from the attribution pipeline. When
    /// below 0.70, a small "needs review" dot appears next to the label so
    /// users can triage where to invest manual rename effort. nil means
    /// "no confidence data" (legacy meetings) — no indicator shown.
    var attributionConfidence: Float? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timestamp
            Text(transcript.formattedTimestamp)
                .font(.caption.monospaced())
                .foregroundStyle(Color.appTextTertiary)
                .frame(width: 44, alignment: .leading)

            // Speaker + text
            VStack(alignment: .leading, spacing: 2) {
                speakerLabel

                Text(transcript.text)
                    .font(.body)
                    .fontWeight(transcript.isMicrophone ? .semibold : .regular)
                    .foregroundStyle(
                        transcript.isMicrophone
                            ? Color.appTextPrimary
                            : Color.appTextSecondary
                    )
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var speakerLabel: some View {
        let displayName = transcript.displayedSpeakerName(
            meeting: meeting,
            userDisplayName: NSFullUserName()
        )
        if let onRename {
            Menu {
                let participants = meeting?.participantList ?? []
                if !participants.isEmpty {
                    ForEach(participants, id: \.self) { name in
                        Button(name) { onRename(.assign(name)) }
                    }
                    Divider()
                }
                Button("Mark as Unknown") { onRename(.assign("Unknown")) }
                Button("Add custom…") { onRename(.custom) }
            } label: {
                renderedLabel(displayName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(isAIAttributed
                  ? "Auto-assigned by AI — click to change"
                  : "Click to rename speaker")
        } else {
            renderedLabel(displayName)
        }
    }

    @ViewBuilder
    private func renderedLabel(_ name: String) -> some View {
        // A label is "unconfirmed" when it still reads as a generic cluster id
        // — Speaker N, Speaker, system. These should look obviously clickable
        // when a rename menu is mounted, so the user discovers they can tap to
        // assign an attendee.
        let unconfirmed = Self.isUnconfirmed(name: name)
        let canAssign = (onRename != nil)

        HStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .fontWeight(transcript.isMicrophone ? .bold : .medium)
                .italic(isAIAttributed)
                .foregroundStyle(
                    transcript.isMicrophone
                        ? Color.appTextPrimary
                        : (unconfirmed && canAssign
                           ? Color.appAccent
                           : Color.appTextSecondary)
                )
            if isAIAttributed {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(Color.appAccent.opacity(0.6))
            }
            // v3.10 #2: low-confidence indicator — small amber dot so the
            // user can see at a glance which speaker labels are *genuinely*
            // uncertain vs routinely AI-attributed. Threshold tuned below
            // baseline cheap-LLM confidence (0.62 Ollama / 0.72 Claude haiku)
            // so the dot only fires for vocative single-vote / unanchored
            // signals (~0.55) — not every Ollama-attributed name. Avoids
            // alarm fatigue (VP review concern).
            let isLowConfidence = (attributionConfidence ?? 1.0) < 0.60
            if let c = attributionConfidence, isLowConfidence, !transcript.isMicrophone {
                Circle()
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .help("Low confidence (\(String(format: "%.0f", c * 100))%) — click name to verify or rename")
            }
            // Show the rename chevron when the name is generic (Speaker N)
            // OR when it's named but low-confidence — both deserve the
            // user's attention, and both can be fixed via the same menu.
            if (unconfirmed || isLowConfidence) && canAssign {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.appAccent.opacity(0.7))
            }
        }
        .padding(.horizontal, unconfirmed && canAssign ? 6 : 0)
        .padding(.vertical, unconfirmed && canAssign ? 2 : 0)
        .background(
            (unconfirmed && canAssign)
                ? Color.appAccent.opacity(0.08)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// True when the label still reads as a generic cluster id — i.e. attribution
    /// didn't pin it down. Used to make the rename affordance visually obvious.
    private static func isUnconfirmed(name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("speaker") { return true }
        if lower == "system" || lower == "other" || lower == "them" { return true }
        if lower == "unknown" { return true }
        return false
    }
}

/// Action emitted by the speaker-label menu in a `TranscriptBubble`.
enum TranscriptBubbleRenameAction {
    /// Assign the cluster to a specific name (participant or "Unknown").
    case assign(String)
    /// User picked "Add custom…" — host should present the custom-name sheet.
    case custom
}

// MARK: - Preview

// #Preview {
//     VStack(spacing: 0) {
//         TranscriptBubble(
//             transcript: Transcript(
//                 meetingId: "preview",
//                 speakerLabel: "mic",
//                 text: "Let's review the quarterly numbers and see where we stand.",
//                 startTime: 602,
//                 endTime: 608
//             )
//         )
//         TranscriptBubble(
//             transcript: Transcript(
//                 meetingId: "preview",
//                 speakerLabel: "system",
//                 text: "Sure, I've prepared the slides for this discussion.",
//                 startTime: 610,
//                 endTime: 615
//             )
//         )
//     }
//     .background(Color.appBackground)
// }
