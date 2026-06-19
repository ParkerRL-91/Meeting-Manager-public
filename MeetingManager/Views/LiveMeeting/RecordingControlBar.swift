import SwiftUI
import Combine
import os
import AVFoundation

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

    /// Input devices for the inline mic-picker shown when the mic disconnects (TASK-104).
    @State private var availableMics: [AVCaptureDevice] = []
    private let micEnumerator = AudioSessionManager()

    /// User explicitly picked a mic from the recovery banner: switch to it immediately
    /// and pin it via the override so the search stops right away (TASK-104).
    private func pickMic(_ device: AVCaptureDevice) {
        appState.settings.micOverrideEnabled = true
        appState.settings.micOverrideDeviceID = device.uniqueID
        Task { await appState.audioCaptureService.switchMicrophone(toUID: device.uniqueID) }
    }

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

            // P3-T02: Active template pill — shows the meeting's current template
            // (skipped when nil/empty/"standard").
            if let templateId = appState.activeMeeting?.templateId,
               !templateId.isEmpty,
               templateId != "standard",
               let label = Self.templateLabel(for: templateId) {
                HStack(spacing: 4) {
                    Image(systemName: Self.templateIcon(for: templateId) ?? "doc.text")
                        .font(.caption2)
                    Text(label)
                        .font(.caption)
                }
                .foregroundStyle(Color.appTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.appSurfaceSecondary)
                .clipShape(Capsule())
                .accessibilityLabel("Template: \(label)")
            }

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

            // Signal-independent mic-health status (TASK-095): shows the mic is
            // live + which device, muted, or not capturing — even while silent,
            // distinct from the talk-time level meter below. Suppressed while the
            // "Reconnecting mic…" banner is up (recovery/self-heal owns that).
            if !appState.isMicRecovering {
                MicHealthStatusPill(health: appState.micHealth)
            }

            // Audio level meters
            AudioLevelIndicator(
                label: "\u{1F3A4}",
                level: appState.micLevel,
                color: .appAccent
            )

            // Inline (non-modal) mic-loss status (TASK-104). The mic disconnected;
            // the call keeps recording via system audio. While searching we show a
            // calm "finding a new one"; if the search window expires we keep the
            // banner up (no alarming popup) and lean on the picker. Either way a
            // dropdown lets the user pick a mic to stop the search immediately.
            if appState.isMicRecovering {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption)
                    Text("Microphone disconnected — finding a new one…")
                        .font(.caption)
                    Menu {
                        if availableMics.isEmpty {
                            Text("No microphones found")
                        } else {
                            ForEach(availableMics, id: \.uniqueID) { mic in
                                Button(mic.localizedName) { pickMic(mic) }
                            }
                        }
                    } label: {
                        Label("Choose mic", systemImage: "chevron.down")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .foregroundStyle(Color.appRecording)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.appRecordingSubtle)
                .clipShape(Capsule())
                .help("Your microphone disconnected. The call is still being recorded via system audio. Pick a microphone to switch right away, or reconnect one and it resumes automatically.")
                .accessibilityLabel("Microphone disconnected, searching for a replacement. The call is still being recorded via system audio. Use the menu to choose a microphone.")
                .task {
                    // Keep the picker list fresh while the banner is up so a mic the
                    // user plugs in AFTER the disconnect appears within a few seconds
                    // (TASK-104). Auto-cancelled when the banner disappears.
                    while !Task.isCancelled {
                        availableMics = micEnumerator.availableInputDevices()
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
            }

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

    // MARK: - Template Helpers (P3-T02)

    /// Label for a template id. Mirrors `MeetingTemplatePickerView.templates` —
    /// duplicated here intentionally to keep the recording bar lightweight; will
    /// be deduped once a shared template registry lands.
    private static func templateLabel(for id: String) -> String? {
        MeetingTemplatePickerView.label(for: id)
    }

    private static func templateIcon(for id: String) -> String? {
        MeetingTemplatePickerView.icon(for: id)
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

// MARK: - Mic Health Status Pill (TASK-095, REQ-6)

/// Signal-independent mic-health pill: reflects liveness (noise floor present),
/// device identity, and mute-state even while the user is silent — so the user
/// can trust the mic before speaking. Distinct from the talk-time level meter.
private struct MicHealthStatusPill: View {
    let health: MicHealthSnapshot

    var body: some View {
        Group {
            if let style {
                HStack(spacing: 4) {
                    Image(systemName: style.icon)
                        .font(.caption)
                    Text(style.text)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(style.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(style.color.opacity(0.12))
                .clipShape(Capsule())
                .help(style.help)
                .accessibilityLabel(style.accessibility)
            }
        }
    }

    private struct Style {
        let icon: String
        let text: String
        let color: Color
        let help: String
        let accessibility: String
    }

    /// nil → render nothing (status unknown before the first health tick).
    private var style: Style? {
        let device = health.deviceName.isEmpty ? "your microphone" : health.deviceName
        switch health.verdict {
        case .live, .quietLive:
            // A noise floor is actually present — affirm the mic is live.
            return Style(
                icon: "mic.fill",
                text: "Live · \(health.deviceName.isEmpty ? "mic" : health.deviceName)",
                color: .appSuccess,
                help: "Recording from \(device) — the mic is live even while you're silent.",
                accessibility: "Microphone live, recording from \(device)"
            )
        case .silentOK:
            // Correct, alive device but no floor right now (a quiet stretch) — we
            // can't see a signal, so don't over-claim "Live". A calm "Listening"
            // status is honest and still reassures the user the mic isn't broken.
            return Style(
                icon: "mic.fill",
                text: "Listening · \(health.deviceName.isEmpty ? "mic" : health.deviceName)",
                color: .appTextSecondary,
                help: "Recording from \(device). No sound right now — Meeting Manager is listening and will pick up your voice when you speak.",
                accessibility: "Microphone on \(device), listening, no sound detected yet"
            )
        case .muted:
            return Style(
                icon: "mic.slash.fill",
                text: "Muted",
                color: .appTextSecondary,
                help: "\(device) is muted. Meeting Manager keeps recording and resumes your voice automatically when you unmute.",
                accessibility: "Microphone muted on \(device). Recording continues; unmute to resume your voice."
            )
        case .deviceMismatch, .dead:
            return Style(
                icon: "exclamationmark.triangle.fill",
                text: "Mic not capturing",
                color: .appWarning,
                help: "Your microphone isn't capturing. Pick your mic in System Settings > Sound > Input — the call audio is still being recorded.",
                accessibility: "Microphone not capturing. Switch device. The call is still being recorded."
            )
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
