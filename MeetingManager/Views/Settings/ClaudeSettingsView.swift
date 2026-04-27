import SwiftUI
import os

/// Settings view for configuring the Claude API key and model selection.
struct ClaudeSettingsView: View {

    // MARK: - Environment

    @Environment(AppState.self) private var appState

    // MARK: - State

    @State private var apiKey: String = ""
    @State private var selectedModel: String = Constants.Defaults.aiModel
    @State private var isTesting = false
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var showAPIKey = false
    @State private var saveError: String?

    private let claudeService = ClaudeService()

    // MARK: - Models

    private let availableModels: [(id: String, label: String)] = [
        ("claude-sonnet-4-20250514", "Claude 4 (Balanced)"),
        ("claude-opus-4-20250514", "Claude 4 (Premium)"),
    ]

    enum ConnectionStatus: Equatable {
        case unknown
        case testing
        case success
        case failed(String)
    }

    // MARK: - Body

    var body: some View {
        @Bindable var appState = appState
        Form {
            aiToggleSection
            apiKeySection
                .disabled(!appState.settings.aiEnabled)
                .opacity(appState.settings.aiEnabled ? 1 : 0.5)
            modelSection
                .disabled(!appState.settings.aiEnabled)
                .opacity(appState.settings.aiEnabled ? 1 : 0.5)
            connectionSection
                .disabled(!appState.settings.aiEnabled)
                .opacity(appState.settings.aiEnabled ? 1 : 0.5)
        }
        .formStyle(.grouped)
        .onAppear(perform: loadSettings)
    }

    // MARK: - Sections

    private var aiToggleSection: some View {
        @Bindable var appState = appState
        return Section {
            Toggle("Enable AI Features", isOn: $appState.settings.aiEnabled)
            if !appState.settings.aiEnabled {
                Text("Transcription and meeting storage will still work. AI summaries, action items, and chat require a Claude API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI Features")
        }
    }

    private var apiKeySection: some View {
        Section {
            HStack {
                Group {
                    if showAPIKey {
                        TextField("sk-ant-...", text: $apiKey)
                    } else {
                        SecureField("sk-ant-...", text: $apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(showAPIKey ? "Hide API key" : "Show API key")
            }

            Button("Save API Key") {
                saveAPIKey()
            }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Your API key is stored securely in the macOS Keychain. Get a key at [console.anthropic.com](https://console.anthropic.com/).")
        }
    }

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $selectedModel) {
                ForEach(availableModels, id: \.id) { model in
                    Text(model.label).tag(model.id)
                }
            }
            .onChange(of: selectedModel) { _, newValue in
                saveModelSelection(newValue)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Balanced is faster and more cost-effective. Premium provides higher quality for complex meetings.")
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Button {
                    testConnection()
                } label: {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                        Text("Testing...")
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                connectionStatusBadge
            }
        }
    }

    @ViewBuilder
    private var connectionStatusBadge: some View {
        switch connectionStatus {
        case .unknown:
            EmptyView()
        case .testing:
            Label("Testing...", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.appSuccess)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    // MARK: - Actions

    private func loadSettings() {
        do {
            if let storedKey = try KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey) {
                apiKey = storedKey
            }
        } catch {
            Logger.ai.error("Failed to load API key: \(error.localizedDescription)")
        }
        selectedModel = appState.settings.claudeModel
    }

    private func saveAPIKey() {
        saveError = nil
        do {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try KeychainHelper.save(trimmedKey, forKey: KeychainHelper.Key.claudeAPIKey)
            apiKey = trimmedKey
            Logger.ai.info("API key saved to Keychain")
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
            Logger.ai.error("Failed to save API key: \(error.localizedDescription)")
        }
    }

    private func saveModelSelection(_ model: String) {
        appState.settings.claudeModel = model
        Logger.ai.info("Model selection changed to \(model)")
    }

    private func testConnection() {
        isTesting = true
        connectionStatus = .testing
        Task {
            let success = await claudeService.testConnection()
            isTesting = false
            connectionStatus = success
                ? .success
                : .failed(claudeService.lastError ?? "Connection failed")
        }
    }
}

// MARK: - Preview

// #Preview("Claude Settings") {
//     ClaudeSettingsView()
//         .frame(width: 500, height: 400)
// }
