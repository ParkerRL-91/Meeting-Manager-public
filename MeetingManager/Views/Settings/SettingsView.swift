import SwiftUI

/// Top-level settings container using a tab-based layout.
struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "waveform") }
                .tag(1)

            TranscriptionSettingsView()
                .tabItem { Label("Transcription", systemImage: "text.word.spacing") }
                .tag(2)

            GoogleCalendarSettingsView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(3)

            ClaudeSettingsView()
                .tabItem { Label("AI (Claude)", systemImage: "brain") }
                .tag(4)

            OnDeviceSettingsView()
                .tabItem { Label("AI (Local)", systemImage: "cpu") }
                .tag(5)

            PromptConfigView()
                .tabItem { Label("Prompts", systemImage: "text.quote") }
                .tag(6)

            TemplateListView()
                .tabItem { Label("Templates", systemImage: "doc.text.fill") }
                .tag(7)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(8)
        }
        .frame(width: 750, height: 500)
        .onChange(of: appState.pendingSettingsTab) { _, tab in
            if let tab {
                selectedTab = tab
                appState.pendingSettingsTab = nil
            }
        }
    }
}
