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
        HStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .fontWeight(transcript.isMicrophone ? .bold : .medium)
                .italic(isAIAttributed)
                .foregroundStyle(
                    transcript.isMicrophone
                        ? Color.appTextPrimary
                        : Color.appTextSecondary
                )
            if isAIAttributed {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(Color.appAccent.opacity(0.6))
            }
        }
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
