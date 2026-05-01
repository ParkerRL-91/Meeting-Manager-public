import SwiftUI
import AppKit
import ServiceManagement
import EventKit
import os

/// Settings view for appearance, startup behaviour, and notification preferences.
struct GeneralSettingsView: View {

    // MARK: - State

    @Environment(AppState.self) private var appState
    @State private var selectedTheme: String = AppSettings.default.theme
    @State private var resetMessage: String?
    @State private var launchAtLogin: Bool = AppSettings.default.launchAtLogin
    @State private var notificationLeadTime: Int = AppSettings.default.notificationLeadTimeMinutes
    @State private var autoGenerateSummary: Bool = false
    @State private var defaultRecipeId: String? = nil
    @State private var recipes: [Recipe] = []
    @State private var autoFollowUpEmail: Bool = false
    @State private var morningBriefEnabled: Bool = false
    @State private var morningBriefHour: Int = 8
    @State private var morningBriefMinute: Int = 30

    // Reminders integration (P4-T02).
    @AppStorage("reminders.autoSend") private var remindersAutoSend: Bool = false
    @AppStorage("reminders.listIdentifier") private var remindersListIdentifier: String = ""
    @State private var remindersLists: [EKCalendar] = []
    @State private var remindersAuthorized: Bool = false

    // MARK: - Body

    var body: some View {
        Form {
            appearanceSection
            startupSection
            notificationSection
            summaryAutomationSection
            remindersSection
            troubleshootingSection
            aboutSection
        }
        .formStyle(.grouped)
        .task {
            // Sync local state from persisted settings. Without this,
            // selectedTheme stays at its `AppSettings.default` initial
            // value and the picker visually disagrees with reality.
            selectedTheme = appState.settings.theme.isEmpty ? "dark" : appState.settings.theme
            launchAtLogin = appState.settings.launchAtLogin
            notificationLeadTime = appState.settings.notificationLeadTimeMinutes
            autoGenerateSummary = appState.settings.autoGenerateSummary
            defaultRecipeId = appState.settings.defaultRecipeId
            autoFollowUpEmail = appState.settings.autoFollowUpEmail
            morningBriefEnabled = appState.settings.morningBriefEnabled
            morningBriefHour = appState.settings.morningBriefHour
            morningBriefMinute = appState.settings.morningBriefMinute
            let repo = RecipeRepository(database: appState.database)
            recipes = (try? await repo.allRecipes()) ?? []
            await refreshRemindersLists()
            Logger.ui.info("[GeneralSettingsView] hydrated; theme=\(selectedTheme, privacy: .public)")
        }
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        // Three explicit Buttons replace the previous segmented Picker. Picker
        // bindings on macOS Settings windows turned out not to fire reliably
        // — likely because the Settings scene's auto-managed state observation
        // intercepts the binding before our setter runs. Buttons guarantee a
        // tap → handler invocation with zero ambiguity.
        Section {
            HStack(spacing: 8) {
                themeButton(label: "Dark", value: "dark")
                themeButton(label: "Light", value: "light")
                themeButton(label: "System", value: "system")
            }

            // Permanent reminder so the bit lands even before any clicks.
            Text("We live our life in the dark. Light mode is not coming.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        } header: {
            Text("Appearance")
        }
    }

    /// One of the three theme buttons. Dark commits the change; Light/System
    /// trigger the refusal alert.
    @ViewBuilder
    private func themeButton(label: String, value: String) -> some View {
        let isSelected = (selectedTheme == value)
        Button {
            Logger.ui.info("[themeButton] tapped value=\(value, privacy: .public)")
            if value == "dark" {
                selectedTheme = "dark"
                persistSetting { $0.theme = "dark" }
                Logger.ui.info("[themeButton] persisted theme=dark")
            } else {
                showLightModeRefusal(attempted: value)
            }
        } label: {
            Text(label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var startupSection: some View {
        Section {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    persistSetting { $0.launchAtLogin = enabled }
                    setLaunchAtLogin(enabled)
                }
        } header: {
            Text("Startup")
        } footer: {
            Text("Automatically start Meeting Manager when you log in to your Mac.")
        }
    }

    private var notificationSection: some View {
        Section {
            Stepper(
                "Remind me \(notificationLeadTime) min before meetings",
                value: $notificationLeadTime,
                in: 1...30
            )
            .onChange(of: notificationLeadTime) { _, newValue in
                persistSetting { $0.notificationLeadTimeMinutes = newValue }
                Logger.ui.info("Notification lead time changed to \(newValue) minutes")
            }

            Toggle("Morning Brief Notification", isOn: $morningBriefEnabled)
                .onChange(of: morningBriefEnabled) { _, enabled in
                    persistSetting { $0.morningBriefEnabled = enabled }
                    appState.settings.morningBriefEnabled = enabled
                    updateMorningBriefNotification(enabled: enabled)
                }

            if morningBriefEnabled {
                HStack {
                    Text("Notification time")
                    Spacer()
                    Picker("Hour", selection: $morningBriefHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(String(format: "%02d", hour)).tag(hour)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 70)
                    .onChange(of: morningBriefHour) { _, newValue in
                        persistSetting { $0.morningBriefHour = newValue }
                        appState.settings.morningBriefHour = newValue
                        updateMorningBriefNotification(enabled: morningBriefEnabled)
                    }

                    Text(":")
                        .foregroundStyle(Color.appTextSecondary)

                    Picker("Minute", selection: $morningBriefMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { minute in
                            Text(String(format: "%02d", minute)).tag(minute)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 70)
                    .onChange(of: morningBriefMinute) { _, newValue in
                        persistSetting { $0.morningBriefMinute = newValue }
                        appState.settings.morningBriefMinute = newValue
                        updateMorningBriefNotification(enabled: morningBriefEnabled)
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Set how many minutes before a meeting to be notified. Enable the Morning Brief to receive a daily summary of your meetings and open items at the configured time.")
        }
    }

    private var summaryAutomationSection: some View {
        Section {
            Toggle("Auto-generate summary after transcription", isOn: $autoGenerateSummary)
                .onChange(of: autoGenerateSummary) { _, enabled in
                    persistSetting { $0.autoGenerateSummary = enabled }
                    appState.settings.autoGenerateSummary = enabled
                }

            if autoGenerateSummary {
                Picker("Default prompt", selection: $defaultRecipeId) {
                    Text("Meeting Summary (default)")
                        .tag(nil as String?)

                    ForEach(recipes) { recipe in
                        Label(recipe.name, systemImage: recipe.category.icon)
                            .tag(recipe.id as String?)
                    }
                }
                .onChange(of: defaultRecipeId) { _, newValue in
                    persistSetting { $0.defaultRecipeId = newValue }
                    appState.settings.defaultRecipeId = newValue
                }
            }

            Toggle("Auto-generate follow-up email after summary", isOn: $autoFollowUpEmail)
                .onChange(of: autoFollowUpEmail) { _, enabled in
                    persistSetting { $0.autoFollowUpEmail = enabled }
                    appState.settings.autoFollowUpEmail = enabled
                }
        } header: {
            Text("Summary Automation")
        } footer: {
            Text("When enabled, a summary is automatically generated 10 minutes after transcription completes using the selected prompt template. The follow-up email option additionally drafts a professional email recap using the built-in Follow-Up Email template.")
        }
    }

    private var remindersSection: some View {
        Section {
            Toggle("Auto-send action items to Reminders", isOn: $remindersAutoSend)

            if remindersAuthorized {
                Picker("Reminders list", selection: $remindersListIdentifier) {
                    Text("Default").tag("")
                    ForEach(remindersLists, id: \.calendarIdentifier) { cal in
                        Text(cal.title).tag(cal.calendarIdentifier)
                    }
                }
            } else {
                Button("Grant Reminders Access") {
                    Task {
                        _ = await RemindersService.shared.requestAccess()
                        await refreshRemindersLists()
                    }
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Action items extracted from meeting summaries can sync to Apple Reminders. Choose which list new items go into.")
        }
    }

    private func refreshRemindersLists() async {
        let service = RemindersService.shared
        remindersAuthorized = service.isAuthorized
        remindersLists = service.availableLists()
    }

    /// Troubleshooting tools — primarily the permission-reset workflow.
    /// Beta users on unsigned/self-signed builds frequently see TCC entries
    /// stick around in System Settings while macOS internally invalidates
    /// the binary-hash binding after an update. Manually toggling the
    /// permission off/on in System Settings is one fix; this button is
    /// the one-click equivalent.
    private var troubleshootingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("If permissions show as granted but the app reports they're missing (common after an update), reset them here. You'll be re-prompted on next use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        resetAppPermissions()
                    } label: {
                        Label("Reset App Permissions", systemImage: "arrow.counterclockwise.circle")
                    }
                    .help("Clears macOS TCC permissions for Microphone, Calendar, and Screen Recording. You'll be prompted to grant them again on next use.")

                    Button {
                        openPrivacySettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gear")
                    }
                    .help("Opens System Settings → Privacy & Security so you can manually toggle permissions.")
                }

                if let resetMessage {
                    Text(resetMessage)
                        .font(.caption)
                        .foregroundStyle(resetMessage.starts(with: "✓") ? .green : .red)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("If permissions keep breaking on every update, the long-term fix is to ship the app with a paid Apple Developer ID + notarization. Until then, this button is the workaround.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Build") {
                Text(appBuild)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("About")
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Show a modal NSAlert refusing the light-mode selection.
    ///
    /// Uses `runModal()` (free-floating, blocking) instead of
    /// `beginSheetModal(for:)`. The sheet variant requires the alert to
    /// attach to a key window, and on macOS Settings (`Settings { ... }`
    /// scene) that lookup is racy — `NSApp.keyWindow` is sometimes nil at
    /// the moment a Picker fires its setter because the segmented control
    /// briefly takes first-responder focus, causing the sheet to silently
    /// fail to present. `runModal()` doesn't care — it always shows.
    ///
    /// The `selectedTheme` reset isn't done here because the custom binding
    /// setter intentionally never updates `selectedTheme` for non-dark
    /// values — the picker re-renders with the unchanged Dark selection
    /// the moment SwiftUI completes its layout pass.
    private func showLightModeRefusal(attempted: String) {
        Logger.ui.info("[showLightModeRefusal] entering for attempt=\(attempted, privacy: .public)")
        // Bring the app forward so the modal isn't hidden behind another window.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Nice try."
        alert.informativeText = "You appear to have clicked \(attempted) mode. There is no reason to do this. We live our life in the dark. Reverting back to dark."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Stay in the dark")
        Logger.ui.info("[showLightModeRefusal] calling runModal()")
        alert.runModal()
        Logger.ui.info("[showLightModeRefusal] modal dismissed")
    }

    /// Reset the app's TCC entries via the system `tccutil` binary. Runs as
    /// the user (no admin password required) — the bundle ID arg scopes the
    /// reset to this app only. After a reset, macOS re-prompts for each
    /// permission the next time the app actually needs it.
    ///
    /// Backstory: self-signed builds (everything before notarization is set
    /// up) sometimes lose their TCC binding across updates because macOS
    /// doesn't fully trust the cert chain. The toggle stays visible in
    /// System Settings but the binary-hash binding is invalid. This is the
    /// one-click fix: nuke the TCC rows and let the app re-request.
    private func resetAppPermissions() {
        Logger.ui.info("[resetAppPermissions] starting reset for com.meetingmanager.app")
        let services = ["Microphone", "Calendar", "Reminders", "ScreenCapture"]
        var failed: [String] = []
        for service in services {
            let task = Process()
            task.launchPath = "/usr/bin/tccutil"
            task.arguments = ["reset", service, "com.meetingmanager.app"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    Logger.ui.info("[resetAppPermissions] reset \(service, privacy: .public) — ok")
                } else {
                    Logger.ui.warning("[resetAppPermissions] reset \(service, privacy: .public) exited with \(task.terminationStatus)")
                    failed.append(service)
                }
            } catch {
                Logger.ui.error("[resetAppPermissions] failed to launch tccutil for \(service, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failed.append(service)
            }
        }
        if failed.isEmpty {
            resetMessage = "✓ Permissions reset. macOS will re-prompt for each on next use."
        } else {
            resetMessage = "Reset partially failed for: \(failed.joined(separator: ", ")). Try the System Settings fallback."
        }
        // Auto-clear the message after 8s so it doesn't linger.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            resetMessage = nil
        }
    }

    /// Open System Settings → Privacy & Security as a manual fallback.
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    private func persistSetting(_ mutation: (inout AppSettings) -> Void) {
        do {
            try AppDatabase.shared.writer.write { db in
                if var settings = try AppSettings.fetchOne(db) {
                    mutation(&settings)
                    try settings.update(db)
                } else {
                    var settings = AppSettings.default
                    mutation(&settings)
                    try settings.insert(db)
                }
            }
        } catch {
            Logger.general.error("Failed to persist setting: \(error.localizedDescription)")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Logger.general.info("Launch at login \(enabled ? "enabled" : "disabled")")
        } catch {
            Logger.general.error("Failed to update launch at login: \(error.localizedDescription)")
        }
    }

    private func updateMorningBriefNotification(enabled: Bool) {
        let service = NotificationService()
        if enabled {
            service.scheduleMorningBrief(
                meetingCount: 0,
                openItemCount: 0,
                hour: morningBriefHour,
                minute: morningBriefMinute
            )
        } else {
            service.cancelMorningBrief()
        }
    }
}

// MARK: - Preview

// #Preview("General Settings") {
//     GeneralSettingsView()
//         .frame(width: 500, height: 400)
// }
