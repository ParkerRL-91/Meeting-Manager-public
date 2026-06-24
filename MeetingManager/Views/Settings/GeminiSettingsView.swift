import SwiftUI
import os

/// Settings view for the Gemini API key, model, and activation.
struct GeminiSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var apiKey: String = ""
    @State private var selectedModel: String = "gemini-2.5-flash"
    @State private var isTesting = false
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var showAPIKey = false
    @State private var saveError: String?

    private let geminiService = GeminiService()

    private let availableModels: [(id: String, label: String)] = [
        ("gemini-2.5-flash", "Gemini 2.5 Flash (Fast)"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro (Premium)"),
    ]

    enum ConnectionStatus: Equatable { case unknown, testing, success, failed(String) }

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section {
                Toggle("Use Gemini for AI", isOn: Binding(
                    get: { appState.settings.aiProvider == .gemini },
                    set: { appState.settings.aiProvider = $0 ? .gemini : .none }
                ))
                if appState.settings.aiProvider != .gemini {
                    Text("Turn this on to use Google Gemini for summaries, action items, and chat. Your key stays saved even when Gemini isn't the active provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Gemini")
            }

            Section {
                HStack {
                    Group {
                        if showAPIKey { TextField("AIza...", text: $apiKey) }
                        else { SecureField("AIza...", text: $apiKey) }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(showAPIKey ? "Hide API key" : "Show API key")
                }
                Button("Save API Key") { saveAPIKey() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error = saveError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("Your API key is stored securely in the macOS Keychain. Get a key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey).")
            }

            Section {
                Picker("Model", selection: $selectedModel) {
                    ForEach(availableModels, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .onChange(of: selectedModel) { _, newValue in
                    appState.settings.geminiModel = newValue
                    Logger.ai.info("Gemini model selection changed to \(newValue)")
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Flash is faster and more cost-effective. Pro provides higher quality for complex meetings.")
            }

            Section("Connection") {
                HStack {
                    Button {
                        testConnection()
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small).padding(.trailing, 4)
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
        .formStyle(.grouped)
        .onAppear(perform: loadSettings)
    }

    @ViewBuilder
    private var connectionStatusBadge: some View {
        switch connectionStatus {
        case .unknown: EmptyView()
        case .testing:
            Label("Testing...", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).font(.caption)
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Color.appSuccess).font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption).lineLimit(2)
        }
    }

    private func loadSettings() {
        do {
            if let storedKey = try KeychainHelper.loadString(forKey: KeychainHelper.Key.geminiAPIKey) {
                apiKey = storedKey
            }
        } catch {
            Logger.ai.error("Failed to load Gemini key: \(error.localizedDescription)")
        }
        selectedModel = appState.settings.geminiModel
    }

    private func saveAPIKey() {
        saveError = nil
        do {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try KeychainHelper.save(trimmed, forKey: KeychainHelper.Key.geminiAPIKey)
            apiKey = trimmed
            Logger.ai.info("Gemini API key saved to Keychain")
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func testConnection() {
        isTesting = true
        connectionStatus = .testing
        Task {
            let success = await geminiService.testConnection()
            isTesting = false
            connectionStatus = success ? .success : .failed(geminiService.lastError ?? "Connection failed")
        }
    }
}
