import SwiftUI
import os

// MARK: - Connection Status

private enum ConnectionStatus: Equatable {
    case unknown
    case testing
    case success
    case failed(String)
}

// MARK: - Cloud AI Config

/// Shared config view for Claude and Gemini — parameterised by the bits that differ.
private struct CloudAIConfigView: View {

    enum Provider {
        case claude, gemini, openai, zai
    }

    let provider: Provider

    @Environment(AppState.self) private var appState

    @State private var apiKey: String = ""
    @State private var showAPIKey = false
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var connectionStatus: ConnectionStatus = .unknown

    @AppStorage(PIIRedactor.settingKey) private var redactCloudPII = false

    private let claudeService = ClaudeService()
    private let geminiService = GeminiService()
    private let openaiService = OpenAICompatibleService(provider: .openAI)
    private let zaiService = OpenAICompatibleService(provider: .zai)

    // MARK: Model lists

    private let claudeModels: [(id: String, label: String)] = [
        ("claude-haiku-4-5", "Claude Haiku 4.5 (Fast)"),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6 (Balanced)"),
        ("claude-opus-4-8", "Claude Opus 4.8 (Premium)"),
    ]

    private let geminiModels: [(id: String, label: String)] = [
        ("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite (Fastest)"),
        ("gemini-2.5-flash", "Gemini 2.5 Flash (Fast)"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro (Premium)"),
        ("gemini-3.1-flash-lite", "Gemini 3.1 Flash-Lite"),
        ("gemini-3.5-flash", "Gemini 3.5 Flash (Newest)"),
        ("gemini-3.1-pro", "Gemini 3.1 Pro"),
    ]

    private let openaiModels: [(id: String, label: String)] = [
        ("gpt-5.4-mini", "GPT-5.4 mini (Fast)"),
        ("gpt-5.5", "GPT-5.5 (Premium)"),
    ]

    private let zaiModels: [(id: String, label: String)] = [
        ("glm-5.2", "GLM-5.2 (Balanced)"),
        ("glm-4.6", "GLM-4.6"),
    ]

    // MARK: Computed helpers

    private var keychainKey: String {
        switch provider {
        case .claude: return KeychainHelper.Key.claudeAPIKey
        case .gemini: return KeychainHelper.Key.geminiAPIKey
        case .openai: return KeychainHelper.Key.openAIAPIKey
        case .zai: return KeychainHelper.Key.zaiAPIKey
        }
    }

    private var placeholder: String {
        switch provider {
        case .claude: return "sk-ant-..."
        case .gemini: return "AIza..."
        case .openai: return "sk-..."
        case .zai: return "Enter z.ai API key"
        }
    }

    private var footerURL: (label: String, url: String) {
        switch provider {
        case .claude:
            return ("console.anthropic.com", "https://console.anthropic.com/")
        case .gemini:
            return ("aistudio.google.com/apikey", "https://aistudio.google.com/apikey")
        case .openai:
            return ("platform.openai.com/api-keys", "https://platform.openai.com/api-keys")
        case .zai:
            return ("z.ai", "https://z.ai")
        }
    }

    // MARK: Body

    var body: some View {
        @Bindable var appState = appState
        return Group {
            apiKeySection
            modelSection
            connectionSection
            redactionSection
        }
        .onAppear(perform: loadKey)
    }

    // MARK: Sections

    private var apiKeySection: some View {
        Section {
            HStack {
                Group {
                    if showAPIKey {
                        TextField(placeholder, text: $apiKey)
                    } else {
                        SecureField(placeholder, text: $apiKey)
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

            Button(isSaving ? "Saving & testing..." : "Save API Key") {
                saveAndTest()
            }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("API Key")
        } footer: {
            let link = footerURL
            Text("Your API key is stored securely in the macOS Keychain. Get a key at [\(link.label)](\(link.url)).")
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        @Bindable var appState = appState
        switch provider {
        case .claude:
            Section {
                Picker("Model", selection: $appState.settings.claudeModel) {
                    ForEach(claudeModels, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Balanced is faster and more cost-effective. Premium provides higher quality for complex meetings.")
            }
        case .gemini:
            Section {
                Picker("Model", selection: $appState.settings.geminiModel) {
                    ForEach(geminiModels, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Flash-Lite is the fastest and most cost-effective and is the default. Flash balances cost and quality; Pro is the highest quality. The 3.x models are the newest generation.")
            }
        case .openai:
            Section {
                Picker("Model", selection: $appState.settings.openaiModel) {
                    ForEach(openaiModels, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Mini is faster and more cost-effective. The full model provides higher quality for complex meetings.")
            }
        case .zai:
            Section {
                Picker("Model", selection: $appState.settings.zaiModel) {
                    ForEach(zaiModels, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("GLM-5.2 is the balanced default. GLM-4.6 is an established, lighter alternative.")
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Button {
                    runTest()
                } label: {
                    if case .testing = connectionStatus {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                        Text("Testing...")
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(
                    connectionStatus == .testing
                    || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Spacer()

                switch connectionStatus {
                case .unknown, .testing:
                    EmptyView()
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
        }
    }

    private var redactionSection: some View {
        Section {
            Toggle(
                "Redact names, emails, and phone numbers before sending to a cloud AI provider",
                isOn: $redactCloudPII
            )
            Text("A reversible, on-device substitution (\u{201C}Person A\u{201D}, \u{201C}person1@redacted.example\u{201D}) applied to summaries, notes, briefs, and chat. Speaker identification is exempt — matching speakers to attendees requires their real names. Heuristic protection, not a guarantee.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func loadKey() {
        do {
            if let stored = try KeychainHelper.loadString(forKey: keychainKey) {
                apiKey = stored
            }
        } catch {
            Logger.ai.error("Failed to load API key: \(error.localizedDescription)")
        }
    }

    private func saveAndTest() {
        saveError = nil
        isSaving = true
        do {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try KeychainHelper.save(trimmed, forKey: keychainKey)
            apiKey = trimmed
            Logger.ai.info("\(String(describing: provider)) API key saved to Keychain")
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
            isSaving = false
            return
        }
        connectionStatus = .testing
        Task {
            let (success, errorMessage) = await runConnection()
            await MainActor.run {
                isSaving = false
                connectionStatus = success
                    ? .success
                    : .failed(errorMessage ?? "Connection failed")
            }
        }
    }

    private func runTest() {
        connectionStatus = .testing
        Task {
            let (success, errorMessage) = await runConnection()
            await MainActor.run {
                connectionStatus = success
                    ? .success
                    : .failed(errorMessage ?? "Connection failed")
            }
        }
    }

    private func runConnection() async -> (Bool, String?) {
        switch provider {
        case .claude:
            let ok = await claudeService.testConnection()
            return (ok, claudeService.lastError)
        case .gemini:
            let ok = await geminiService.testConnection()
            return (ok, geminiService.lastError)
        case .openai:
            let ok = await openaiService.testConnection()
            return (ok, openaiService.lastError)
        case .zai:
            let ok = await zaiService.testConnection()
            return (ok, zaiService.lastError)
        }
    }
}

// MARK: - Local AI Config

/// Ollama config extracted from OnDeviceSettingsView — all install/status/model
/// logic preserved verbatim; only the toggle section is absent (the picker replaces it).
private struct LocalAIConfigView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        statusSection
        aboutSection
    }

    // MARK: Status (verbatim from OnDeviceSettingsView)

    @ViewBuilder
    private var statusSection: some View {
        let installer = appState.ollamaInstaller
        let service = appState.ollamaService

        if installer.phase.isActive {
            Section {
                installProgressRow
            } header: {
                Text("Setup")
            }
        } else if case .failed(let msg) = installer.phase {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Setup failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline.weight(.medium))
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await installer.retry(model: appState.settings.ollamaModel) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Setup")
            }
        } else if case .ready = installer.phase {
            runningStatusSection
        } else if service.isReachable {
            runningStatusSection
        } else {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ollama isn't running")
                            .font(.subheadline.weight(.medium))
                        Text("Ollama may need to be restarted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Start") {
                        Task { await installer.setupIfNeeded(model: appState.settings.ollamaModel) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Status")
            }
        }
    }

    private var installProgressRow: some View {
        let installer = appState.ollamaInstaller
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(installer.phase.label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            if let progress = installer.phase.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
            }

            Text(installPhaseDetail(installer.phase))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func installPhaseDetail(_ phase: OllamaInstaller.Phase) -> String {
        switch phase {
        case .downloadingApp:
            return "Downloading Ollama from GitHub (≈60 MB)..."
        case .installing:
            return "Extracting and moving Ollama to ~/Applications..."
        case .launching:
            return "Opening Ollama..."
        case .waitingForServer:
            return "Waiting for Ollama server to start (this may take up to 30 seconds)..."
        case .pullingModel(let name, _):
            return "Downloading \(name) — this may take a few minutes (~2 GB)."
        default:
            return ""
        }
    }

    @ViewBuilder
    private var runningStatusSection: some View {
        let service = appState.ollamaService
        @Bindable var appState = appState

        Section {
            HStack {
                ollamaStatusBadge
                Spacer()
                Button {
                    Task { await service.refreshStatus() }
                } label: {
                    if service.isCheckingStatus {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Refresh")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(service.isCheckingStatus)
            }

            if service.isReachable {
                modelPickerRow
            }
        } header: {
            Text("Ollama Status")
        } footer: {
            if !service.isReachable {
                Text("Ollama is installed but not running. Select a different provider and back to restart it.")
            } else if service.availableModels.isEmpty {
                Text("Ollama is running but has no models. Switch away and back to download one.")
            }
        }
    }

    @ViewBuilder
    private var ollamaStatusBadge: some View {
        let service = appState.ollamaService
        if service.isCheckingStatus {
            Label("Checking...", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else if service.isReachable {
            Label(
                "\(service.availableModels.count) model(s) available",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(Color.appSuccess)
            .font(.caption)
        } else {
            Label("Ollama not running", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private var modelPickerRow: some View {
        @Bindable var appState = appState
        let models = appState.ollamaService.availableModels
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: $appState.settings.ollamaModel) {
                Text("Auto (Dynamic)").tag("auto")
                Divider()
                Text("Qwen3 4B Instruct — fast, recommended").tag("qwen3:4b-instruct")
                Text("Qwen3 8B — higher quality, larger").tag("qwen3:8b")
                Text("Qwen2.5 3B Instruct — fastest, smallest").tag("qwen2.5:3b-instruct")
                Divider()
                ForEach(models.filter { !["qwen3:4b-instruct", "qwen3:8b", "qwen2.5:3b-instruct"].contains($0) }, id: \.self) { model in
                    Text(model).tag(model)
                }
                if appState.settings.ollamaModel != "auto"
                    && !["qwen3:4b-instruct", "qwen3:8b", "qwen2.5:3b-instruct"].contains(appState.settings.ollamaModel)
                    && !models.contains(appState.settings.ollamaModel) {
                    Text(appState.settings.ollamaModel).tag(appState.settings.ollamaModel)
                }
            }
            .onChange(of: appState.settings.ollamaModel) { _, newModel in
                guard newModel != "auto" else { return }
                Task { await appState.ollamaInstaller.setupIfNeeded(model: newModel) }
            }

            if appState.settings.ollamaModel == "auto" {
                Label("Auto adapts to each meeting — Qwen3 4B handles short and standard meetings; Qwen3 8B takes over for marathon sessions and long transcripts.", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.settings.ollamaModel.contains("qwen2.5:7b") {
                Label("Qwen2.5 7B Instruct generates summaries directly without a reasoning step, so it finishes in roughly one to three minutes instead of the many minutes the Qwen3 thinking models take. It uses about 5 GB of memory.", systemImage: "hare.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.settings.ollamaModel.contains("qwen2.5:3b") {
                Label("Qwen2.5 3B Instruct is the fastest option and finishes most summaries in under a minute, using about 2 GB of memory. It is a good fit for shorter meetings.", systemImage: "hare.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.settings.ollamaModel.contains("qwen3:4b-instruct") {
                Label("Qwen3 4B Instruct is the recommended default — about 2.5 GB, and it generates summaries directly without a reasoning step, so it finishes in seconds rather than the many minutes the thinking models take.", systemImage: "hare.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.settings.ollamaModel.contains("qwen3:4b") {
                Label("This is the thinking-only Qwen3 4B build, which cannot disable its reasoning step and can make summaries take many minutes. Switch to Qwen3 4B Instruct for fast, direct summaries.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.settings.ollamaModel.contains("qwen3:8b") {
                Label("Qwen3 8B uses about 5.5 GB of memory and produces noticeably better summaries and action items on meetings longer than 30 minutes.", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.settings.ollamaModel.contains("3b") {
                Label("Using a 3B Llama model — slower but works on any Mac. Switch to auto to pick up the newer Qwen3 4B/8B ladder.", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.settings.ollamaModel.contains("8b") {
                Label("Using an 8B Llama model — switch to auto to pick up the newer Qwen3 ladder, which is materially better at structured output.", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: About (verbatim from OnDeviceSettingsView)

    private var aboutSection: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 4) {
                Text("On-device summarization uses Ollama, a free local AI runtime. When enabled, Meeting Manager installs Ollama automatically — nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("**Auto (Dynamic)** picks the best model based on transcript length — 3B for quick meetings, 8B for long group calls. Timeouts adjust automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("**llama3.2:3b** — works on any Mac, slower on large transcripts. Recommended for Macs with ≤16GB RAM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("**llama3.1:8b** — better quality for meetings over 30 min. Needs ~6GB free RAM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - AISettingsView

/// Single "AI" settings tab with a provider dropdown.
/// Replaces the three separate AI tabs (Claude, Local, Gemini).
struct AISettingsView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Form {
            providerSection

            switch appState.settings.aiProvider {
            case .none:
                offSection
            case .local:
                LocalAIConfigView()
            case .claude:
                CloudAIConfigView(provider: .claude)
            case .gemini:
                CloudAIConfigView(provider: .gemini)
            case .openai:
                CloudAIConfigView(provider: .openai)
            case .zai:
                CloudAIConfigView(provider: .zai)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if appState.settings.aiProvider == .local {
                Task { await appState.ollamaService.refreshStatus() }
            }
        }
    }

    // MARK: Provider picker

    private var providerSection: some View {
        @Bindable var appState = appState
        return Section {
            Picker("AI Provider", selection: $appState.settings.aiProvider) {
                Text("Off").tag(AIProvider.none)
                Text("On-Device (Local)").tag(AIProvider.local)
                Text("Claude").tag(AIProvider.claude)
                Text("Gemini").tag(AIProvider.gemini)
                Text("OpenAI").tag(AIProvider.openai)
                Text("z.ai").tag(AIProvider.zai)
            }
            .pickerStyle(.menu)
        } header: {
            Text("Provider")
        } footer: {
            Text("Choose which AI backend powers summaries, action items, and chat. Recording and transcription work regardless of this setting.")
        }
        .onChange(of: appState.settings.aiProvider) { _, newProvider in
            if newProvider == .local {
                Task { await appState.ollamaInstaller.setupIfNeeded(model: appState.settings.ollamaModel) }
            }
        }
    }

    // MARK: Off state

    private var offSection: some View {
        Section {
            Text("AI features are off. Choose a provider above to enable summaries, action items, and chat. Recording and transcription still work.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
