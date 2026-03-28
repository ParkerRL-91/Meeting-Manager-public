import SwiftUI

/// Top-level settings container using a tab-based layout.
struct SettingsView: View {

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

            PromptConfigView()
                .tabItem { Label("Prompts", systemImage: "text.quote") }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - Preview

#Preview("Settings") {
    SettingsView()
}
