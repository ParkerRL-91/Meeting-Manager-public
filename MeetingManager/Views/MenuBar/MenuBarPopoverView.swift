import SwiftUI
import Combine

/// The SwiftUI view shown inside the menu bar popover/dropdown.
/// Displays recording status, elapsed time, audio levels, and quick actions.
/// Adapts its content based on whether a meeting is recording, a call is detected, or idle.
struct MenuBarPopoverView: View {
    @Environment(AppState.self) private var appState

    @State private var elapsedSeconds: Int = 0
    @State private var timer: AnyCancellable?

    var body: some View {
        VStack(spacing: 0) {
            if appState.isRecording {
                recordingSection
            } else if appState.detectedCallApp != nil {
                callDetectedSection
            } else {
                idleSection
            }

            Divider()
                .padding(.horizontal, 12)

            actionsSection
        }
        .frame(width: 280)
        .background(Color.appBackground)
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    // MARK: - Recording State

    private var recordingSection: some View {
        VStack(spacing: 12) {
            // Header with pulsing dot
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.appRecording)
                    .frame(width: 10, height: 10)
                    .modifier(PulsingModifier())

                Text("Recording")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)

                Spacer()

                Text(formattedElapsedTime)
                    .font(.body.monospaced())
                    .foregroundStyle(Color.appTextSecondary)
            }

            // Meeting title
            if let meeting = appState.activeMeeting {
                Text(meeting.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Audio levels
            HStack(spacing: 16) {
                audioMeter(
                    label: "Mic",
                    icon: "mic.fill",
                    level: appState.micLevel,
                    color: .appAccent
                )
                audioMeter(
                    label: "System",
                    icon: "speaker.wave.2.fill",
                    level: appState.systemLevel,
                    color: .appSuccess
                )
            }

            // Stop button
            Button(action: {
                appState.stopRecording()
                dismissPopover()
            }) {
                HStack {
                    Image(systemName: "stop.fill")
                    Text("Stop Recording")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.appRecording)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Call Detected State

    private var callDetectedSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "phone.fill")
                    .foregroundStyle(Color.appSuccess)

                Text("\(appState.detectedCallApp ?? "Call") Detected")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)

                Spacer()
            }

            Button(action: {
                NotificationCenter.default.post(name: .createNewMeeting, object: nil)
                dismissPopover()
            }) {
                HStack {
                    Image(systemName: "record.circle")
                    Text("Start Recording")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.appAccent)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Idle State

    private var idleSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.appAccent)

                Text("Meeting Manager")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)

                Spacer()
            }

            // Model status: downloading, error, or ready
            if appState.isLoadingModel {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Downloading transcription model...")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                        Spacer()
                        Text("\(Int(appState.modelDownloadProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    ProgressView(value: appState.modelDownloadProgress)
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = appState.transcriptionService.lastError, !appState.isLoadingModel {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.appWarning)
                            .font(.caption)
                        Text("Model download failed")
                            .font(.caption)
                            .foregroundStyle(Color.appTextPrimary)
                    }
                    Text(error.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(2)
                    Button(action: { appState.retryModelLoad() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry Download")
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if appState.transcriptionService.isModelLoaded {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.appSuccess)
                        .font(.caption)
                    Text("Transcription ready")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 2) {
            if !appState.isRecording {
                menuButton(title: "New Meeting", icon: "plus.circle", shortcut: "N") {
                    NotificationCenter.default.post(name: .createNewMeeting, object: nil)
                    dismissPopover()
                }
                // Quick memo (TASK-052): mic-only, full pipeline.
                menuButton(title: "Quick Memo", icon: "mic.badge.plus", shortcut: nil) {
                    appState.startQuickMemo()
                    dismissPopover()
                }
            }

            menuButton(title: "Open Meeting Manager", icon: "macwindow", shortcut: "O") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                dismissPopover()
            }

            Divider()
                .padding(.horizontal, 12)

            menuButton(title: "Check for Updates...", icon: "arrow.triangle.2.circlepath", shortcut: nil) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .openUpdateSettings, object: nil)
                dismissPopover()
            }

            menuButton(title: "Quit", icon: "power", shortcut: "Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Components

    private func audioMeter(label: String, icon: String, level: Float, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 14)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.appSurfaceSecondary)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * CGFloat(min(level * 20, 1.0))), height: 4)
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func menuButton(title: String, icon: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 20)

                Text(title)
                    .font(.body)

                Spacer()

                if let shortcut {
                    Text("\u{2318}\(shortcut)")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(MenuBarButtonStyle())
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
            .sink { _ in updateElapsed() }
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

    private func dismissPopover() {
        NotificationCenter.default.post(name: .dismissMenuBarPopover, object: nil)
    }
}

// MARK: - Pulsing Modifier

private struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Button Style

private struct MenuBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Color.appSurfaceSecondary : Color.clear)
            )
    }
}

// MARK: - Notification

extension Notification.Name {
    static let dismissMenuBarPopover = Notification.Name("dismissMenuBarPopover")
}
