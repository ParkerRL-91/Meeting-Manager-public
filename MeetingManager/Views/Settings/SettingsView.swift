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

            VoiceProfilesSettingsView()
                .tabItem { Label("Voices", systemImage: "waveform.badge.mic") }
                .tag(8)

            KnowledgeBaseSettingsView()
                .tabItem { Label("Knowledge Base", systemImage: "books.vertical") }
                .tag(9)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(10)
        }
        // Default to a comfortably wide window. Settings tabs vary in
        // density: Prompts has a 3-pane layout (list / editor / reference)
        // which was cramped at 750×500 — buttons truncated to "Reset to..."
        // and the reference pane clipped tab labels at the top.
        // min sizes let the user shrink, ideal gives a sensible default.
        .frame(
            minWidth: 800,
            idealWidth: 1100,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .onChange(of: appState.pendingSettingsTab) { _, tab in
            if let tab {
                selectedTab = tab
                appState.pendingSettingsTab = nil
            }
        }
    }
}
