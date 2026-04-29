import SwiftUI

/// Simple About panel showing app version and build info.
struct AboutSettingsView: View {

    var body: some View {
        Form {
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
                Text("Meeting Manager")
            }

            Section {
                LabeledContent("Updates") {
                    Text("Download the latest version from GitHub Releases.")
                        .foregroundStyle(.secondary)
                }

                Button("Open GitHub Releases") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/ParkerRL-91/Meeting-Manager/releases")!)
                }
            } header: {
                Text("Software Updates")
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
