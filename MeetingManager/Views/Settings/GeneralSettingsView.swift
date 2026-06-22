import SwiftUI
import AppKit
import ServiceManagement
import os

/// Settings view for appearance, startup behaviour, and notification preferences.
struct GeneralSettingsView: View {

    // MARK: - State

    @Environment(AppState.self) private var appState
    @State private var selectedTheme: String = AppSettings.default.theme
    @State private var launchAtLogin: Bool = AppSettings.default.launchAtLogin
    @State private var notificationLeadTime: Int = AppSettings.default.notificationLeadTimeMinutes
    @State private var autoGenerateSummary: Bool = false
    @State private var defaultRecipeId: String? = nil
    @State private var recipes: [Recipe] = []
    @State private var autoFollowUpEmail: Bool = false
    @State private var morningBriefEnabled: Bool = false
    @State private var morningBriefHour: Int = 8
    @State private var morningBriefMinute: Int = 30
    @State private var taskDueAlertsEnabled: Bool = AppSettings.default.taskDueAlertsEnabled

    // Recording storage location (hydrated in .task; refreshed after changes).
    @State private var recordingPath: String = ""
    @State private var recordingWritable: Bool = true
    @State private var recordingIsCustom: Bool = false

    // One-time Apple Reminders import (PRJ-013 Phase 2). The outbound push was removed.
    @State private var isImporting = false
    @State private var importSummary: String?

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                Toggle("Run background AI work on battery", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "backgroundAI.allowOnBattery") },
                    set: { UserDefaults.standard.set($0, forKey: "backgroundAI.allowOnBattery") }
                ))
                Text("History indexing, weekly digests, and other non-urgent AI batches normally wait for AC power and a quiet moment. They always wait while you're recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            appearanceSection
            startupSection
            recordingsSection
            notificationSection
            summaryAutomationSection
            tasksSection
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
            taskDueAlertsEnabled = appState.settings.taskDueAlertsEnabled
            refreshRecordingStatus()
            let repo = RecipeRepository(database: appState.database)
            recipes = (try? await repo.allRecipes()) ?? []
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

    private var recordingsSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: recordingWritable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(recordingWritable ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recordingPath.isEmpty ? "Default location" : recordingPath)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(recordingWritable
                         ? "Audio recordings are saved here."
                         : "This folder can't be written to — choose another.")
                        .font(.caption)
                        .foregroundStyle(recordingWritable ? Color.secondary : Color.orange)
                }
                Spacer()
            }
            HStack {
                Button("Change…") { chooseRecordingFolder() }
                Button("Show in Finder") { revealRecordingFolder() }
                if recordingIsCustom {
                    Button("Use Default") { useDefaultRecordingFolder() }
                }
                Spacer()
            }
        } header: {
            Text("Recordings")
        } footer: {
            Text("Meeting audio is saved here, then transcribed on-device. If a recording ever fails because this location isn't writable, change it here. Choosing a folder also grants Meeting Manager permission to write to it.")
        }
    }

    private func refreshRecordingStatus() {
        recordingPath = RecordingStorage.shared.preferredDirectory().path
        recordingWritable = RecordingStorage.shared.isPreferredWritable()
        recordingIsCustom = RecordingStorage.shared.customDirectory != nil
    }

    private func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder where Meeting Manager can save audio recordings."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RecordingStorage.shared.customDirectory = url
        refreshRecordingStatus()
    }

    private func useDefaultRecordingFolder() {
        RecordingStorage.shared.customDirectory = nil
        refreshRecordingStatus()
    }

    private func revealRecordingFolder() {
        let url = RecordingStorage.shared.preferredDirectory()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

            Button("Test Reminder HUD") {
                let meeting = appState.upcomingMeetings.first ?? Meeting(
                    id: "test-hud",
                    title: "Test Meeting (HUD preview)",
                    scheduledStartDate: Date().addingTimeInterval(60),
                    scheduledEndDate: Date().addingTimeInterval(30 * 60),
                    status: .scheduled,
                    meetLink: "https://meet.google.com/test-hud"
                )
                NotificationCenter.default.post(
                    name: .meetingHUDShow,
                    object: nil,
                    userInfo: ["meetingId": meeting.id]
                )
                // Stash the synthetic meeting on AppState so AppDelegate's lookup hits.
                if !appState.upcomingMeetings.contains(where: { $0.id == meeting.id }) {
                    appState.upcomingMeetings.append(meeting)
                }
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

            Toggle("Alert me when a task is due", isOn: $taskDueAlertsEnabled)
                .onChange(of: taskDueAlertsEnabled) { _, enabled in
                    persistSetting { $0.taskDueAlertsEnabled = enabled }
                    appState.settings.taskDueAlertsEnabled = enabled
                    Task { await appState.refreshTaskNotifications() }
                }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Set how many minutes before a meeting to be notified. Enable the Morning Brief to receive a daily summary of your meetings, open items, and due tasks at the configured time. Task alerts fire a single reminder at each task's due or reminder time.")
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

            // TASK-070: default ON, so read via object(forKey:) with a true fallback.
            Toggle("Learn my style from summary edits", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "summary.learnFromEdits") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "summary.learnFromEdits") }
            ))

            // TASK-079: coarse on-device tone read. Default ON.
            Toggle("Show meeting tone (sentiment)", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "sentiment.enabled") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "sentiment.enabled") }
            ))
        } header: {
            Text("Summary Automation")
        } footer: {
            Text("When enabled, a summary is automatically generated 10 minutes after transcription completes using the selected prompt template. The follow-up email option additionally drafts a professional email recap using the built-in Follow-Up Email template. Style learning shows new summaries how you edited past ones, so they arrive closer to your preferred shape; with the local model this only fits alongside shorter meetings.")
        }
    }

    private var tasksSection: some View {
        Section {
            Button {
                runReminderImport()
            } label: {
                HStack(spacing: 8) {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text("Import your existing tasks from Apple Reminders")
                }
            }
            .disabled(isImporting)

            if let importSummary {
                Text(importSummary)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        } header: {
            Text("Tasks")
        } footer: {
            Text("Bring your existing Apple Reminders into Meeting Manager as accepted tasks on the board. This is a one-time import, not an ongoing sync, and it skips reminders you have already imported.")
        }
    }

    private func runReminderImport() {
        isImporting = true
        importSummary = nil
        Task {
            // EXEMPT: user-initiated, modal-scoped one-time import; not post-meeting AI work.
            let summary = await TaskImportService().importFromReminders()
            await MainActor.run {
                isImporting = false
                importSummary = summary.message
            }
        }
    }

    /// Troubleshooting tools — primarily the permission-reset workflow.
    /// Uses the same `PermissionResetButton` component that the gate and
    /// onboarding use, so behaviour is guaranteed identical across all three
    /// surfaces. (Earlier versions had a bespoke implementation here; the
    /// shared component replaces it.)
    private var troubleshootingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                PermissionResetButton(style: .compact)

                Button {
                    openPrivacySettings()
                } label: {
                    Label("Open System Settings → Privacy", systemImage: "gear")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .help("Opens System Settings → Privacy & Security so you can manually toggle permissions.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        let service = appState.notificationService
        guard enabled else {
            service.cancelMorningBrief()
            return
        }
        // Fold current overdue / due-today task counts into the single daily
        // digest (PRJ-013 Phase 5). Counts reflect the moment of scheduling —
        // the digest is one recurring summary, not a per-item ping.
        let hour = morningBriefHour
        let minute = morningBriefMinute
        Task {
            let counts = (try? await appState.taskRepository.overdueAndDueTodayCounts()) ?? (overdue: 0, dueToday: 0)
            service.scheduleMorningBrief(
                meetingCount: 0,
                openItemCount: 0,
                overdueTaskCount: counts.overdue,
                dueTodayTaskCount: counts.dueToday,
                hour: hour,
                minute: minute
            )
        }
    }
}

// MARK: - Preview

// #Preview("General Settings") {
//     GeneralSettingsView()
//         .frame(width: 500, height: 400)
// }
