import SwiftUI
import Combine

/// The SwiftUI view shown inside the menu bar popover/dropdown (TASK-126 redesign).
///
/// One continuous surface, two block types:
///   1. Attention blocks — the ONLY elements with a colored left rail + tinted
///      fill (switch suggestion) or an inset tinted card (silent-capture
///      warning). They mean "act on this".
///   2. Flat list rows — icon + title + trailing shortcut, hover highlight.
///
/// Hierarchy is carried by rail + fill + spacing, not dividers: there is exactly
/// ONE structural hairline in the whole popover — the fence between the primary
/// action zone and the menu zone. Stacking order is stable in every state:
/// attention (switch) → recording status → degraded warning (silence) →
/// primary action → degraded warning (calendar health) → hairline → menu zone.
///
/// Urgency color ramp, one role per color: red = live/destructive; orange =
/// act-now switch; amber = degraded silence; green = healthy; blue (`appInfo`) =
/// neutral primary.
///
/// Presentation only — every input is a read-only `AppState` property and every
/// action routes through an existing `AppState` method / notification.
struct MenuBarPopoverView: View {
    @Environment(AppState.self) private var appState

    @State private var elapsedSeconds: Int = 0
    @State private var timer: AnyCancellable?

    private static let sidePadding: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            // Attention zone: the switch suggestion (TASK-118) sits at the very
            // top and PERSISTS through the soft-timeout demote (the popover is
            // the recovery surface for a heads-down user), unlike the floating
            // window and in-app banner which hide. Demote only de-escalates the
            // presentation here.
            if let suggestion = appState.pendingSwitchSuggestion {
                if appState.switchSuggestionDemoted {
                    switchSuggestionDemoted(suggestion)
                } else {
                    switchSuggestionFull(suggestion)
                }
            }

            if appState.isRecording {
                recordingHeader
                if appState.captureSilenceWarning {
                    silenceWarningCard
                }
                stopButton
            } else if appState.detectedCallApp != nil {
                callDetectedSection
            } else {
                idleSection
            }

            // TASK-132: the popover is the app's only always-visible surface, so a
            // signed-out or stalled calendar showed nowhere at all unless Home
            // happened to be mounted. Below the state section so it can never
            // displace live recording controls, and non-dismissible — the popover
            // is transient, so there is no episode bookkeeping to keep.
            if let reason = calendarHealthReason {
                calendarHealthCard(reason)
            }

            // The single structural hairline — the fence above the menu zone.
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 1)

            menuZone
        }
        .frame(width: 300)
        .background(Color.appBackground)
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    // MARK: - Switch suggestion (attention block, filled — states 6 & 7)

    private func switchSuggestionFull(_ suggestion: AppState.SwitchSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Prose combines into ONE VoiceOver stop (twice-regressed
            // requirement); the buttons below stay separately focusable.
            VStack(alignment: .leading, spacing: 0) {
                eyebrow("New meeting detected", color: .orange, size: 10.5, tracking: 0.7)

                Text(suggestion.detectedTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)

                Text(SwitchSuggestionCopy.signalCaption(for: suggestion))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)

                Text(SwitchSuggestionCopy.acceptCaption(
                    currentTitle: appState.activeMeeting?.title ?? "this meeting",
                    firedAt: suggestion.firedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                Button {
                    appState.acceptSwitchSuggestion()
                    dismissPopover()
                } label: {
                    Text(SwitchSuggestionCopy.acceptLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(SwitchSuggestionCopy.acceptLabel). Stops \(appState.activeMeeting?.title ?? "this meeting"), starts \(suggestion.detectedTitle).")

                Button {
                    appState.dismissSwitchSuggestion(byUser: true)
                } label: {
                    Text(SwitchSuggestionCopy.declineLabel(for: suggestion.origin))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.appSurfaceSecondary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.appBorderStrongest, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SwitchSuggestionCopy.declineLabel(for: suggestion.origin))
            }
            .padding(.top, 10)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, Self.sidePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.orange).frame(width: 3)
        }
    }

    // MARK: - Switch suggestion (attention block, demoted — state 8)

    private func switchSuggestionDemoted(_ suggestion: AppState.SwitchSuggestion) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                eyebrow("New meeting detected", color: .orange.opacity(0.45), size: 10, tracking: 0.6)
                Text(suggestion.detectedTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                appState.acceptSwitchSuggestion()
                dismissPopover()
            } label: {
                Text("Switch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.orange.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(SwitchSuggestionCopy.acceptLabel). Stops \(appState.activeMeeting?.title ?? "this meeting"), starts \(suggestion.detectedTitle).")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, Self.sidePadding)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.orange.opacity(0.45)).frame(width: 3)
        }
    }

    // MARK: - Recording state (header + meters)

    /// Active mic name for the silent-capture warning (mirrors the
    /// RecordingStrip picker's label source).
    private var silenceWarningMicName: String {
        let name = appState.micHealth.deviceName
        return name.isEmpty ? "Microphone" : name
    }

    private var recordingHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.appRecording)
                    .frame(width: 7, height: 7)
                    .modifier(PulsingModifier())

                Text("Recording")
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(Color.appRecording)

                Spacer()

                Text(formattedElapsedTime)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.appTextPrimary)
            }

            if let meeting = appState.activeMeeting {
                Text(meeting.title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 7)
            }

            VStack(spacing: 9) {
                audioMeter(icon: "mic.fill", iconColor: .appInfoTint, level: appState.micLevel, fill: .appInfo)
                audioMeter(icon: "speaker.wave.2.fill", iconColor: .appSuccess, level: appState.systemLevel, fill: .appSuccess)
            }
            .padding(.top, 12)
        }
        .padding(.top, 13)
        .padding(.bottom, 12)
        .padding(.horizontal, Self.sidePadding)
    }

    // MARK: - Silent-capture warning (degraded, amber — states 5 & 7)

    /// TASK-124: sustained silent-capture warning — visible here so a user
    /// recording from the menu bar with the main window closed sees it. Label
    /// only, never touches the audio stack. When a switch suggestion is also
    /// present (state 7) the fill is dropped so only the top-most attention
    /// block (switch) stays filled — the single-filled-accent rule.
    private var silenceWarningCard: some View {
        let quieted = appState.pendingSwitchSuggestion != nil && !appState.switchSuggestionDemoted
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appWarning)
                    .accessibilityHidden(true)
                // The label sits on the Text (not the containing VStack) so the
                // link button below stays its own focusable element instead of
                // being demoted to a custom action on a combined group.
                Text("No audio detected for over a minute — check your microphone (\(silenceWarningMicName)) and audio. Recording continues.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.appWarning.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Warning: no audio detected for over a minute. Check your microphone \(silenceWarningMicName) and audio. Recording continues.")
            }
            // The remedy (the mic picker) lives in the main window's recording
            // strip — give the menu-bar user a one-click path to it.
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                dismissPopover()
            } label: {
                Text("Open window to switch mic ›")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appWarning)
            }
            .buttonStyle(.plain)
            .padding(.leading, 21)
            .accessibilityLabel("Open the main window to switch microphone")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(quieted ? Color.clear : Color.appWarning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.appWarning.opacity(0.28), lineWidth: 1)
                )
        )
        .padding(.horizontal, Self.sidePadding)
        .padding(.bottom, 12)
    }

    // MARK: - Calendar health (degraded, amber — TASK-132)

    private var calendarHealthReason: CalendarHealthReason? {
        switch appState.calendarSyncManager.health {
        case .degraded(let reason), .disconnected(let reason): return reason
        case .unknown, .healthy: return nil
        }
    }

    /// Copy comes from `CalendarHealthReason.bannerMessage`, shared with Home's
    /// banner so the two surfaces can't describe the same outage differently.
    private func calendarHealthCard(_ reason: CalendarHealthReason) -> some View {
        // Same single-filled-accent rule as `silenceWarningCard`: drop the fill
        // when a higher-urgency block above is already filled.
        let quieted = (appState.pendingSwitchSuggestion != nil && !appState.switchSuggestionDemoted)
            || (appState.isRecording && appState.captureSilenceWarning)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appWarning)
                    .accessibilityHidden(true)
                // Label on the Text, not the VStack, so the button below stays its
                // own focusable element.
                Text(reason.bannerMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.appWarning.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Calendar warning: \(reason.bannerMessage)")
            }
            Button {
                // Close first: the OAuth sheet anchors to a real window, and the
                // popover would be dismissed out from under the handshake anyway.
                dismissPopover()
                // EXEMPT: user-driven OAuth handshake, not post-meeting AI/network
                // work — TaskQueueManager doesn't apply.
                Task { await appState.reconnectGoogleCalendar() }
            } label: {
                Text("Reconnect")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appWarning)
            }
            .buttonStyle(.plain)
            .padding(.leading, 21)
            .accessibilityLabel("Reconnect Google Calendar")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(quieted ? Color.clear : Color.appWarning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.appWarning.opacity(0.28), lineWidth: 1)
                )
        )
        .padding(.horizontal, Self.sidePadding)
        .padding(.bottom, 12)
    }

    // MARK: - Primary action: Stop (recording)

    private var stopButton: some View {
        Button {
            appState.stopRecording()
            dismissPopover()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12))
                Text("Stop Recording")
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(Color.appRecording)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.appRecording.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.appRecording.opacity(0.32), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Self.sidePadding)
        .padding(.bottom, 12)
    }

    // MARK: - Call detected state (primary action: Start Recording)

    private var callDetectedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSuccess)
                    .accessibilityHidden(true)
                Text("Call detected")
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(Color.appSuccess)
            }

            Text("\(appState.detectedCallApp ?? "Call") call is live")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)

            Text("Not recording yet.")
                .font(.system(size: 12))
                .foregroundStyle(Color.appTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 3)

            Button {
                NotificationCenter.default.post(name: .createNewMeeting, object: nil)
                dismissPopover()
            } label: {
                Text("Start Recording")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.appInfo)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.top, 11)
        }
        .padding(.top, 13)
        .padding(.bottom, 12)
        .padding(.horizontal, Self.sidePadding)
    }

    // MARK: - Idle state

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Meeting Manager")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)

            // Model status: downloading, error, or ready. Blue = neutral progress.
            Group {
                if appState.isLoadingModel {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Downloading transcription model")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.appTextSecondary)
                            Spacer()
                            Text("\(Int(appState.modelDownloadProgress * 100))%")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Color.appTextPrimary)
                        }
                        // Same 4pt/2pt track construction as the audio
                        // meters (spec state 2) — a system ProgressView has a
                        // different height and track color.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.appSurfaceSecondary)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.appInfo)
                                    .frame(width: max(0, geo.size.width * CGFloat(appState.modelDownloadProgress)))
                            }
                        }
                        .frame(height: 4)
                        .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                } else if let error = appState.transcriptionService.lastError, !appState.isLoadingModel {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.appWarning)
                            Text("Model download failed")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.appTextPrimary)
                        }
                        Text(error.localizedDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appTextSecondary)
                            .lineLimit(2)
                        Button { appState.retryModelLoad() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry Download")
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appInfo)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 7)
                } else if appState.transcriptionService.isModelLoaded {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.appSuccess)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text("Transcription model ready")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 7)
                }
            }
        }
        .padding(.top, 13)
        .padding(.bottom, 12)
        .padding(.horizontal, Self.sidePadding)
    }

    // MARK: - Menu zone

    private var menuZone: some View {
        VStack(spacing: 2) {
            // Context-sensitive control (TASK-121): a plain click takes the
            // app-wide fast path (`.createNewMeeting` → startNewMeeting) when
            // nothing maps to the click; when candidates exist (or while
            // recording) the click opens the picker instead. While recording its
            // rows become "Switch to: …" actions — the recovery path for a
            // missed/expired suggestion. Restyled to the menu-zone row idiom via
            // the `.compact` style; Menu-vs-Button semantics unchanged.
            NewMeetingButton(
                style: .compact,
                primaryAction: {
                    NotificationCenter.default.post(name: .createNewMeeting, object: nil)
                    dismissPopover()
                },
                onSelect: { dismissPopover() }
            )
            .environment(appState)

            if !appState.isRecording && appState.detectedCallApp == nil {
                // Quick memo (TASK-052): mic-only, full pipeline. True-idle
                // only (spec state 1-2) — the call-detected state offers
                // Start Recording, not a memo.
                menuButton(title: "Quick Memo", icon: "mic", shortcut: nil) {
                    appState.startQuickMemo()
                    dismissPopover()
                }
            }

            menuButton(title: "Open Meeting Manager", icon: "macwindow", shortcut: "O") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                dismissPopover()
            }

            // Row-group separator (subtle) — NOT the structural fence.
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            menuButton(title: "Check for Updates…", icon: "arrow.down.circle", shortcut: nil) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .openUpdateSettings, object: nil)
                dismissPopover()
            }

            menuButton(title: "Quit", icon: "power", shortcut: "Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }

    // MARK: - Components

    private func eyebrow(_ text: String, color: Color, size: CGFloat, tracking: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .textCase(.uppercase)
            .tracking(tracking)
            .foregroundStyle(color)
    }

    private func audioMeter(icon: String, iconColor: Color, level: Float, fill: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(iconColor)
                .frame(width: 15)
                .accessibilityHidden(true)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.appSurfaceSecondary)
                        .frame(height: 4)

                    // Flat fill only — no shadow/blur (§6: meters redraw ~10Hz).
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill)
                        .frame(width: max(0, geo.size.width * CGFloat(min(level * 20, 1.0))), height: 4)
                        .animation(.linear(duration: 0.09), value: level)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 4)
        }
    }

    private func menuButton(title: String, icon: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appTextPrimary)

                Spacer()

                if let shortcut {
                    Text("\u{2318}\(shortcut)")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Color.appTextMuted)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
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

/// Recording-dot pulse: 1.6s ease-in-out, opacity + slight scale. Kept cheap
/// (no shadow/blur) so it can share the popover with the ~10Hz meters.
private struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.35 : 1.0)
            .scaleEffect(isPulsing ? 0.8 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Button Style

/// Flat menu-zone row style: transparent at rest, `appSurfaceSecondary` on
/// hover, `appSurfacePressed` while pressed, 7pt radius to match the design's
/// row rounding.
private struct MenuBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(configuration.isPressed
                              ? Color.appSurfacePressed
                              : (hovering ? Color.appSurfaceSecondary : Color.clear))
                )
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let dismissMenuBarPopover = Notification.Name("dismissMenuBarPopover")
}
