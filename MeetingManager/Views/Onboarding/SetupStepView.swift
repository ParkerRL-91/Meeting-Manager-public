import SwiftUI

struct SetupStepView: View {
    @State private var apiKey: String = ""
    @State private var apiKeySaved = false
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("Setup")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Connect optional integrations to get the most out of Meeting Manager. You can always configure these later in Settings.")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            VStack(spacing: 20) {
                // Claude API Key
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "brain")
                            .foregroundStyle(Color.appAccent)
                        Text("Claude API Key")
                            .font(.headline)
                            .foregroundStyle(Color.appTextPrimary)

                        Spacer()

                        if apiKeySaved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.appSuccess)
                        }
                    }

                    Text("Enables AI-powered summaries, action items, and chat")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)

                    HStack(spacing: 8) {
                        SecureField("sk-ant-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        Button("Save") {
                            saveAPIKey()
                        }
                        .disabled(apiKey.isEmpty)

                        Button {
                            testConnection()
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(!apiKeySaved || isTesting)
                    }

                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.contains("Success") ? Color.appSuccess : Color.appWarning)
                    }
                }

                Divider()
                    .background(Color.appSeparator)

                // Google Calendar
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundStyle(Color.appAccent)
                        Text("Google Calendar")
                            .font(.headline)
                            .foregroundStyle(Color.appTextPrimary)
                    }

                    Text("Automatically detect upcoming meetings and sync event details")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)

                    Button("Connect Google Calendar") {
                        // Calendar connection handled by GoogleAuthManager in Settings
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 480)

            Text("You can skip these and set them up later in Settings.")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            let claude = ClaudeService()
            let success = await claude.testConnection()
            isTesting = false
            testResult = success ? "Success — Claude API is connected!" : "Failed — check your API key"
        }
    }

    private func saveAPIKey() {
        guard !apiKey.isEmpty else { return }
        do {
            try KeychainHelper.save(apiKey, forKey: KeychainHelper.Key.claudeAPIKey)
            apiKeySaved = true
        } catch {
            print("Failed to save API key: \(error)")
        }
    }
}

// #Preview {
//     SetupStepView()
//         .frame(width: 600, height: 550)
//         .background(Color.appBackground)
//         .preferredColorScheme(.dark)
// }
