import SwiftUI

@main
struct MeetingManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState.sharedOrCreate()
    @State private var onboardingManager = OnboardingManager()
    @State private var permissionsReady = false

    var body: some Scene {
        WindowGroup {
            if !onboardingManager.isCompleted {
                OnboardingView(onboardingManager: onboardingManager)
                    .environment(appState)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 600, minHeight: 450)
            } else if !permissionsReady {
                PermissionGateView(permissionsReady: $permissionsReady)
                    .environment(appState)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 600, minHeight: 450)
            } else {
                ContentView()
                    .environment(appState)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Reset Onboarding (Testing)") {
                    onboardingManager.reset()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Meeting") {
                    NotificationCenter.default.post(name: .createNewMeeting, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.newMeeting)

                Button("Search Everything…") {
                    appState.showGlobalSearch = true
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Quick Memo") {
                    NotificationCenter.default.post(name: .startQuickMemo, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.quickMemo)
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
                    NotificationCenter.default.post(name: .exportMeeting, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.exportMeeting)

                Divider()

                Button("Copy Summary") {
                    NotificationCenter.default.post(name: .copySummary, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.copySummary)
            }

            CommandMenu("Navigate") {
                Button("Summary") {
                    NotificationCenter.default.post(name: .switchTab, object: "summary")
                }
                .keyboardShortcut(KeyboardShortcuts.tabSummary)

                Button("Transcript") {
                    NotificationCenter.default.post(name: .switchTab, object: "transcript")
                }
                .keyboardShortcut(KeyboardShortcuts.tabTranscript)

                Button("Notes") {
                    NotificationCenter.default.post(name: .switchTab, object: "notes")
                }
                .keyboardShortcut(KeyboardShortcuts.tabNotes)

                Divider()

                Button("Find...") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut(KeyboardShortcuts.search)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }

        // System-wide task capture (PRJ-013 Phase 6). The menu-bar icon opens
        // quick-add from anywhere; "Open" deep-links into the task board.
        MenuBarExtra("Add Task", systemImage: "checklist") {
            TaskQuickAddView(
                onOpenTask: { id in
                    appState.selectedTaskId = id
                    appState.sidebarDestination = .taskBoard
                    NSApp.activate(ignoringOtherApps: true)
                }
            )
            .environment(appState)
            .preferredColorScheme(.dark)
            .frame(width: 360)
        }
        .menuBarExtraStyle(.window)
    }
}
