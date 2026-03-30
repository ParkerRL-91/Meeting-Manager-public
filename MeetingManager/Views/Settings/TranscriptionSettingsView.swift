import SwiftUI
import os

/// Settings view for the Whisper transcription model and language.
struct TranscriptionSettingsView: View {

    // MARK: - State

    @State private var language: String = "en"

    // MARK: - Body

    var body: some View {
        Form {
            modelSection
            languageSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private var modelSection: some View {
        Section {
            LabeledContent("Model") {
                Text(WhisperModel.largev3.displayName)
                    .foregroundStyle(.primary)
            }

            LabeledContent("Download Size") {
                Text(WhisperModel.largev3.downloadSizeDescription)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Memory Usage") {
                Text("~\(WhisperModel.largev3.estimatedMemoryMB) MB")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Meeting Manager uses the Large v3 model for maximum transcription accuracy.")
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
