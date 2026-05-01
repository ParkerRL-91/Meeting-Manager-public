import SwiftUI
import ServiceManagement
import EventKit
import os

/// Settings view for appearance, startup behaviour, and notification preferences.
struct GeneralSettingsView: View {

    // MARK: - State

    @Environment(AppState.self) private var appState
    @State private var selectedTheme: String = AppSettings.default.theme
    @State private var showLightModeAlert: Bool = false
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
            aboutSection
        }
        .formStyle(.grouped)
        // Alert lives at the Form level — when attached inside a Section
        // (or worse, inside the Picker's onChange), macOS sometimes silently
        // drops the presentation. Keeping it at the top of the view tree
        // makes it reliably reach the window.
        .alert("Nice try.", isPresented: $showLightModeAlert) {
            Button("Stay in the dark", role: .cancel) {
                // Revert AFTER the user dismisses, not before — gives the
                // picker a moment to visually show what they clicked while
                // the alert is up, then snaps back.
                selectedTheme = "dark"
                persistSetting { $0.theme = "dark" }
            }
        } message: {
            Text("You appear to have clicked light mode. There is no reason to do this. We live our life in the dark. Reverting back to dark.")
        }
        .task {
            autoGenerateSummary = appState.settings.autoGenerateSummary
            defaultRecipeId = appState.settings.defaultRecipeId
            autoFollowUpEmail = appState.settings.autoFollowUpEmail
            morningBriefEnabled = appState.settings.morningBriefEnabled
            morningBriefHour = appState.settings.morningBriefHour
            morningBriefMinute = appState.settings.morningBriefMinute
            let repo = RecipeRepository(database: appState.database)
            recipes = (try? await repo.allRecipes()) ?? []
            await refreshRemindersLists()
        }
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: $selectedTheme) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
                Text("System").tag("system")
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedTheme) { _, newValue in
                // No light mode exists. Bounce back to dark with a wink.
                // We don't bother handling .system either — it'd flip to light
                // half the time, defeating the joke.
                guard newValue != "dark" else {
                    persistSetting { $0.theme = newValue }
                    Logger.ui.info("Theme changed to \(newValue)")
                    return
                }
                Logger.ui.info("User attempted theme=\(newValue) — reverting to dark")
                showLightModeAlert = true
                // Don't revert here — the alert's dismiss button does the
                // revert. Setting selectedTheme back to "dark" inline races
                // the alert presentation and cancels it before it can show.
            }
        } header: {
            Text("Appearance")
        }
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
