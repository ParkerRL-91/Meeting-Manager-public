import SwiftUI
import os

/// Settings view for selecting the Whisper transcription model and language.
struct TranscriptionSettingsView: View {

    // MARK: - State

    @State private var selectedModel: WhisperModel = .tinyEn
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
            Picker("Model", selection: $selectedModel) {
                ForEach(WhisperModel.allCases) { model in
                    HStack {
                        Text(model.displayName)
                        Spacer()
                        Text("~\(model.estimatedMemoryMB) MB RAM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(model)
                }
            }
            .onChange(of: selectedModel) { _, newValue in
                persistSetting { $0.whisperModel = newValue.rawValue }
                Logger.transcription.info("Whisper model changed to \(newValue.displayName)")
            }

            LabeledContent("Download Size") {
                Text(selectedModel.downloadSizeDescription)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Memory Usage") {
                Text("~\(selectedModel.estimatedMemoryMB) MB")
                    .foregroundStyle(.secondary)
            }

            if let warning = selectedModel.memoryWarning {
                Label {
                    Text(warning)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.appWarning)
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Larger models produce more accurate transcriptions but require more memory and may be slower on older hardware.")
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

    // MARK: - Persistence

    private func persistSetting(_ mutation: (inout AppSettings) -> Void) {
        do {
            try AppDatabase.shared.writer.write { db in
                if var settings = try AppSettings.fetchOne(db) {
                    mutation(&settings)
                    try settings.update(db)
                } else {
                    var settings = AppSettings.default
                    mutation(&settings)
                    try settings.insert(db)
                }
            }
        } catch {
            Logger.transcription.error("Failed to persist setting: \(error.localizedDescription)")
        }
    }
}

// MARK: - Preview

// #Preview("Transcription Settings") {
//     TranscriptionSettingsView()
//         .frame(width: 500, height: 400)
// }
