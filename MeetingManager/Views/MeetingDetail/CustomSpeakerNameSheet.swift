import SwiftUI

/// Small sheet for the "Add custom…" entry in the Layer 3 speaker-rename
/// menu. TextField + Save/Cancel; rejects empty / whitespace-only names.
struct CustomSpeakerNameSheet: View {
    let currentName: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Speaker")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)

            Text("Enter a name to use for this speaker throughout the transcript.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

            TextField("Speaker name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            draft = currentName
            fieldFocused = true
        }
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let value = trimmed
        guard !value.isEmpty else { return }
        onSave(value)
        dismiss()
    }
}
