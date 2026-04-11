import SwiftUI
import os

/// Settings view for the Whisper transcription model and language.
struct TranscriptionSettingsView: View {

    // MARK: - State

    @Environment(AppState.self) private var appState
    @State private var language: String = "en"

    private var selectedModel: WhisperModel {
        WhisperModel(rawValue: appState.settings.whisperModel) ?? .largev3turbo
    }

    // MARK: - Body

    var body: some View {
        @Bindable var appState = appState
        Form {
            modelSection
            modelInfoSection
            languageSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private var modelSection: some View {
        @Bindable var appState = appState
        return Section {
            Picker("Transcription Model", selection: Binding(
                get: { appState.settings.whisperModel },
                set: { newValue in
                    appState.settings.whisperModel = newValue
                    Logger.transcription.info("Whisper model changed to \(newValue)")
                }
            )) {
                ForEach(WhisperModel.allCases) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                        Text(model.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(model.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Model")
        } footer: {
            Text("Turbo is recommended for most users — near-identical accuracy with much lower resource usage. Restart the app after changing models.")
        }
    }

    private var modelInfoSection: some View {
        Section {
            LabeledContent("Download Size") {
                Text(selectedModel.downloadSizeDescription)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Memory Usage") {
                Text("~\(selectedModel.estimatedMemoryMB) MB")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Selected Model Info")
        }
    }

    private var languageSection: some View {
        Section {
            TextField("Language Code", text: $language)
                .textFieldStyle(.roundedBorder)
                .onChange(of: language) { _, newValue in
                    Logger.transcription.info("Language changed to \(newValue)")
                }
        } header: {
            Text("Language")
        } footer: {
            Text("BCP-47 language code used as a hint for transcription. The default \"en\" targets English.")
        }
    }
}
