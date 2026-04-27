import SwiftUI
import Combine
import os

/// Top bar displaying recording status, editable meeting title, elapsed time, audio levels, and stop control.
struct RecordingControlBar: View {
    let meetingId: String
    @Environment(AppState.self) private var appState

    @State private var elapsedSeconds: Int = 0
    @State private var timer: AnyCancellable?

    /// Editable title — initialized from the active meeting, auto-saved on commit/focus loss.
    @State private var editableTitle: String = ""
    @State private var isEditing = false
    @FocusState private var titleFocused: Bool

    /// Gate on the stop button so users don't accidentally end a meeting. Surfaces a
    /// confirmationDialog with explicit copy about what "stop" does.
    @State private var showStopConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing recording indicator
            RecordingDot()

            Text("Recording")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)

            // P2-T02: Transcribing heartbeat — shown only while recording AND
            // the Apple Speech engine is actively producing transcripts.
            TranscribingPill()

            // Elapsed time
            Text(formattedElapsedTime)
                .font(.body.monospaced())
                .foregroundStyle(Color.appTextSecondary)

            // Separator
            Text("·")
                .foregroundStyle(Color.appTextTertiary)

            // Editable meeting name — click to rename, auto-saves on Enter or focus loss
            if isEditing {
                TextField("Meeting name", text: $editableTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .focused($titleFocused)
                    .frame(maxWidth: 250)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitTitle() }
                    }
            } else {
                HStack(spacing: 4) {
                    Text(appState.activeMeeting?.title ?? "New Meeting")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)

                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                }
                .onTapGesture {
                    editableTitle = appState.activeMeeting?.title ?? ""
                    isEditing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        titleFocused = true
                    }
                }
                .help("Click to rename meeting")
            }

            Spacer()

            // Participant count badge — shown when at least 1 participant is known
            // (from calendar invite or screen detection)
            if let meeting = appState.activeMeeting, !meeting.participantList.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                    Text("\(meeting.participantList.count)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(Color.appTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.appSurface.opacity(0.6))
                .clipShape(Capsule())
                .help(meeting.participantList.joined(separator: ", "))
            }

            // Audio level meters
            AudioLevelIndicator(
                label: "\u{1F3A4}",
                level: appState.micLevel,
                color: .appAccent
            )

            AudioLevelIndicator(
                label: "\u{1F50A}",
                level: appState.systemLevel,
                color: .appSuccess
            )

            // Stop button
            Button(action: {
                // Commit any pending title edit before prompting for confirmation.
                if isEditing { commitTitle() }
                showStopConfirmation = true
            }) {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.appRecording)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Stop Recording")
            .accessibilityLabel("Stop recording")
            .accessibilityHint("Ends the meeting and starts transcription")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appSurface)
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
        .confirmationDialog(
            "Stop recording?",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Recording", role: .destructive) {
                appState.stopRecording()
            }
            Button("Keep Recording", role: .cancel) { }
        } message: {
            Text("This ends the meeting and begins transcription. You can't resume this recording afterwards.")
        }
    }

    // MARK: - Title Editing

    private func commitTitle() {
        isEditing = false
        titleFocused = false
        let trimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != appState.activeMeeting?.title else { return }

        Task {
            guard var meeting = appState.activeMeeting else { return }
            meeting.title = trimmed
            do {
                try await appState.meetingRepository.save(&meeting)
                appState.activeMeeting = meeting
                appState.loadMeetings()
            } catch {
                Logger.general.error("Failed to save meeting title: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Timer

    private var formattedElapsedTime: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startTimer() {
        updateElapsed()
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                updateElapsed()
            }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func updateElapsed() {
        guard let start = appState.activeMeeting?.startDate else {
            elapsedSeconds = 0
            return
        }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
    }
}

// MARK: - Transcribing Pill (P2-T02)

/// Small "● Transcribing" pill that appears next to the Recording indicator
/// while live transcription is producing segments. Mirrors the Recording pill's
/// styling but in `Color.appSuccess`. The transcriber's `isActive` flag isn't
/// `@Observable`, so we sample it on a low-frequency timer (1Hz) — calm and
/// cheap, no spinner, no percentage.
private struct TranscribingPill: View {
    @Environment(AppState.self) private var appState
    @State private var isTranscribing = false
    @State private var pollTimer: AnyCancellable?

    var body: some View {
        Group {
            if isTranscribing {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.appSuccess)
                        .frame(width: 8, height: 8)
                    Text("Transcribing")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appSuccess)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.appSuccess.opacity(0.12))
                .clipShape(Capsule())
                .accessibilityLabel("Transcribing")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isTranscribing)
        .onAppear(perform: startPolling)
        .onDisappear(perform: stopPolling)
    }

    private func startPolling() {
        updateState()
        pollTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in updateState() }
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
        isTranscribing = false
    }

    private func updateState() {
        let active = appState.isRecording && appState.appleSpeechTranscriber.isActive
        if active != isTranscribing {
            isTranscribing = active
        }
    }
}

// MARK: - Recording Dot

/// A pulsing red dot that indicates active recording.
private struct RecordingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.appRecording)
            .frame(width: 10, height: 10)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Preview

// #Preview {
//     RecordingControlBar(meetingId: "preview-123")
//         .environment(AppState())
// }
