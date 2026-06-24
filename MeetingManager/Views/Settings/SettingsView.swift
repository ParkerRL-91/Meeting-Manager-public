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

            GeminiSettingsView()
                .tabItem { Label("AI (Gemini)", systemImage: "sparkles") }
                .tag(6)

            PromptConfigView()
                .tabItem { Label("Prompts", systemImage: "text.quote") }
                .tag(7)

            TemplateListView()
                .tabItem { Label("Templates", systemImage: "doc.text.fill") }
                .tag(8)

            VoiceProfilesSettingsView()
                .tabItem { Label("Voices", systemImage: "waveform.badge.mic") }
                .tag(9)

            KnowledgeBaseSettingsView()
                .tabItem { Label("Knowledge Base", systemImage: "books.vertical") }
                .tag(10)

            IntegrationsSettingsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
                .tag(11)

            TaskStagesSettingsView()
                .tabItem { Label("Task Stages", systemImage: "rectangle.split.3x1") }
                .tag(12)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(13)
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
