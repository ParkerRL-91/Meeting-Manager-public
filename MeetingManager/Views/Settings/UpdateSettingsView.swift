import SwiftUI
import Sparkle

/// Settings view for configuring automatic app updates.
struct UpdateSettingsView: View {

    @ObservedObject private var updaterViewModel: UpdaterViewModel

    init(updater: SPUUpdater) {
        self.updaterViewModel = UpdaterViewModel(updater: updater)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updaterViewModel.automaticallyChecksForUpdates)

                HStack {
                    Button("Check for Updates Now") {
                        updaterViewModel.checkForUpdates()
                    }
                    .disabled(!updaterViewModel.canCheckForUpdates)

                    Spacer()

                    if let lastCheck = updaterViewModel.lastUpdateCheck {
                        Text("Last checked: \(lastCheck, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Software Updates")
            } footer: {
                Text("Meeting Manager will periodically check for updates and notify you when a new version is available.")
            }

            Section {
                LabeledContent("Current Version") {
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
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

/// ViewModel bridging Sparkle's Combine publishers to SwiftUI.
@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    var lastUpdateCheck: Date? {
        updater.lastUpdateCheckDate
    }

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater

        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
