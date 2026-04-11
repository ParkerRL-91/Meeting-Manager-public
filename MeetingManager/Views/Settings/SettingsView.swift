import SwiftUI
import Sparkle

/// Top-level settings container using a tab-based layout.
struct SettingsView: View {

    @ObservedObject var updateService: UpdateService

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "waveform") }

            TranscriptionSettingsView()
                .tabItem { Label("Transcription", systemImage: "text.word.spacing") }

            GoogleCalendarSettingsView()
                .tabItem { Label("Calendar", systemImage: "calendar") }

            ClaudeSettingsView()
                .tabItem { Label("Claude", systemImage: "brain") }

            OnDeviceSettingsView()
                .tabItem { Label("On-Device", systemImage: "cpu") }

            PromptConfigView()
                .tabItem { Label("Prompts", systemImage: "text.quote") }

            TemplateListView()
                .tabItem { Label("Templates", systemImage: "doc.text.fill") }

            UpdateSettingsView(updater: updateService.updater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 750, height: 500)
    }
}

// MARK: - Preview

// #Preview("Settings") {
//     SettingsView(updateService: UpdateService())
// }
