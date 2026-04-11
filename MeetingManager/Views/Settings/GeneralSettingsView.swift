import SwiftUI
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

    // MARK: - Body

    var body: some View {
        Form {
            appearanceSection
            startupSection
            notificationSection
            summaryAutomationSection
            aboutSection
        }
        .formStyle(.grouped)
        .task {
            autoGenerateSummary = appState.settings.autoGenerateSummary
            defaultRecipeId = appState.settings.defaultRecipeId
            autoFollowUpEmail = appState.settings.autoFollowUpEmail
            let repo = RecipeRepository(database: appState.database)
            recipes = (try? await repo.allRecipes()) ?? []
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
                persistSetting { $0.theme = newValue }
                Logger.ui.info("Theme changed to \(newValue)")
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
        } header: {
            Text("Notifications")
        } footer: {
            Text("How many minutes before a scheduled meeting you would like to be notified.")
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
}

// MARK: - Preview

// #Preview("General Settings") {
//     GeneralSettingsView()
//         .frame(width: 500, height: 400)
// }
