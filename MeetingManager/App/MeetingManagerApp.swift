import SwiftUI
import Sparkle

@main
struct MeetingManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var onboardingManager = OnboardingManager()
    @StateObject private var updateService = UpdateService()

    var body: some Scene {
        WindowGroup {
            if onboardingManager.isCompleted {
                ContentView()
                    .environment(appState)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                OnboardingView(onboardingManager: onboardingManager)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 600, minHeight: 450)
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updateService.checkForUpdates()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Meeting") {
                    NotificationCenter.default.post(name: .createNewMeeting, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.newMeeting)
            }

            CommandMenu("Meeting") {
                Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                    if appState.isRecording {
                        NotificationCenter.default.post(name: .stopRecording, object: nil)
                    } else {
                        NotificationCenter.default.post(name: .startRecording, object: nil)
                    }
                }
                .keyboardShortcut(KeyboardShortcuts.toggleRecording)

                Button("Export Meeting...") {
                    NotificationCenter.default.post(name: Notification.Name("exportMeeting"), object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.exportMeeting)

                Divider()

                Button("Copy Summary") {
                    NotificationCenter.default.post(name: Notification.Name("copySummary"), object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.copySummary)
            }

            CommandMenu("Navigate") {
                Button("Summary") {
                    NotificationCenter.default.post(name: Notification.Name("switchTab"), object: "summary")
                }
                .keyboardShortcut(KeyboardShortcuts.tabSummary)

                Button("Transcript") {
                    NotificationCenter.default.post(name: Notification.Name("switchTab"), object: "transcript")
                }
                .keyboardShortcut(KeyboardShortcuts.tabTranscript)

                Button("Notes") {
                    NotificationCenter.default.post(name: Notification.Name("switchTab"), object: "notes")
                }
                .keyboardShortcut(KeyboardShortcuts.tabNotes)

                Button("Action Items") {
                    NotificationCenter.default.post(name: Notification.Name("switchTab"), object: "actionItems")
                }
                .keyboardShortcut(KeyboardShortcuts.tabActionItems)

                Divider()

                Button("Find...") {
                    NotificationCenter.default.post(name: Notification.Name("focusSearch"), object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.search)
            }
        }

        Settings {
            SettingsView(updateService: updateService)
                .environment(appState)
                .preferredColorScheme(.dark)
        }
    }
}
