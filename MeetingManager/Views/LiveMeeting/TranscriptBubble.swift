import SwiftUI

/// A single transcript segment row showing timestamp, speaker, and text.
struct TranscriptBubble: View {
    let transcript: Transcript
    var meeting: Meeting? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timestamp
            Text(transcript.formattedTimestamp)
                .font(.caption.monospaced())
                .foregroundStyle(Color.appTextTertiary)
                .frame(width: 44, alignment: .leading)

            // Speaker + text
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.displayedSpeakerName(meeting: meeting, userDisplayName: NSFullUserName()))
                    .font(.caption)
                    .fontWeight(transcript.isMicrophone ? .bold : .medium)
                    .foregroundStyle(
                        transcript.isMicrophone
                            ? Color.appTextPrimary
                            : Color.appTextSecondary
                    )

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
