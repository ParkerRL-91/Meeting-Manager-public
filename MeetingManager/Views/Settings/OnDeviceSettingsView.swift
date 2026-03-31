import SwiftUI
import os

/// Settings for the optional Ollama-backed on-device summarization mode.
/// Handles the full Ollama install flow in-app — no manual setup required.
struct OnDeviceSettingsView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Form {
            toggleSection
            statusSection
            aboutSection
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await appState.ollamaService.refreshStatus() }
        }
    }

    // MARK: - Toggle

    private var toggleSection: some View {
        @Bindable var appState = appState
        return Section {
            Toggle("Use On-Device Summarization", isOn: Binding(
                get: { appState.settings.useLocalLLM },
                set: { newValue in
                    appState.settings.useLocalLLM = newValue
                    if newValue {
                        Task { await appState.ollamaInstaller.setupIfNeeded(model: appState.settings.ollamaModel) }
                    }
                }
            ))
        } header: {
            Text("On-Device AI")
        } footer: {
            Text("Summarizes meetings locally using Ollama — no data leaves your Mac.")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        let installer = appState.ollamaInstaller
        let service = appState.ollamaService

        if installer.phase.isActive {
            // Install in progress
            Section {
                installProgressRow
            } header: {
                Text("Setup")
            }
        } else if case .failed(let msg) = installer.phase {
            // Install failed
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
            // Just finished installing — show live status
            runningStatusSection
        } else if service.isReachable || !appState.settings.useLocalLLM {
            // Normal state: Ollama already running or toggle is off
            runningStatusSection
        } else if appState.settings.useLocalLLM {
            // Toggle is on but Ollama isn't running (e.g. after restart)
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
                Text("Ollama is installed but not running. Turn the toggle off and back on to restart it.")
            } else if service.availableModels.isEmpty {
                Text("Ollama is running but has no models. Toggle on-device mode to download one.")
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
        return Picker("Model", selection: $appState.settings.ollamaModel) {
            ForEach(models, id: \.self) { model in
                Text(model).tag(model)
            }
            if !models.contains(appState.settings.ollamaModel) {
                Text(appState.settings.ollamaModel).tag(appState.settings.ollamaModel)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 4) {
                Text("On-device summarization uses Ollama, a free local AI runtime. When enabled, Meeting Manager installs Ollama automatically — nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Summary quality depends on the model. llama3.2:3b is a good balance of speed and quality.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}
