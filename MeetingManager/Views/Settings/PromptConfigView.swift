import SwiftUI
import os

/// Settings view for editing and previewing the AI summarization prompt template.
struct PromptConfigView: View {

    // MARK: - State

    @State private var template: String = ""
    @State private var showPreview = false
    @State private var hasChanges = false

    private let promptManager = PromptManager()

    // MARK: - Body

    var body: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 300)

            referencePane
                .frame(minWidth: 200, idealWidth: 220)
        }
        .onAppear {
            template = promptManager.loadTemplate()
        }
    }

    // MARK: - Editor Pane

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Prompt Template")
                    .font(.headline)
                    .foregroundStyle(.appTextPrimary)

                Spacer()

                Button("Reset to Default") {
                    template = DefaultPrompts.meetingSummary
                    hasChanges = true
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    promptManager.saveTemplate(template)
                    hasChanges = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
            }

            TextEditor(text: $template)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.appSeparator, lineWidth: 1)
                )
                .onChange(of: template) { _, _ in
                    hasChanges = true
                }

            // Preview toggle
            DisclosureGroup("Preview", isExpanded: $showPreview) {
                previewSection
            }
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Reference Pane

    private var referencePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Variables")
                .font(.headline)
                .foregroundStyle(.appTextPrimary)

            Text("Use these placeholders in your template. They will be replaced with actual meeting data when generating a summary.")
                .font(.caption)
                .foregroundStyle(.appTextSecondary)

            Divider()

            ForEach(PromptManager.availableVariables, id: \.token) { variable in
                VStack(alignment: .leading, spacing: 2) {
                    Text(variable.token)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.appAccent)
                        .textSelection(.enabled)

                    Text(variable.description)
                        .font(.caption)
                        .foregroundStyle(.appTextSecondary)
                }
                .padding(.vertical, 4)
            }

            Spacer()

            tipSection
        }
        .padding()
        .background(Color.appSurface)
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample output with placeholder data:")
                .font(.caption)
                .foregroundStyle(.appTextSecondary)

            ScrollView {
                Text(promptManager.previewSubstitution(template: template))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.appTextPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 200)
            .background(Color.appSurfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.top, 4)
    }

    // MARK: - Tips

    private var tipSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label("Tips", systemImage: "lightbulb")
                    .font(.caption.bold())
                    .foregroundStyle(.appWarning)

                Text("Use Markdown formatting in your template for structured output. Ask for specific sections like action items or decisions.")
                    .font(.caption2)
                    .foregroundStyle(.appTextSecondary)
            }
        }
    }
}

// MARK: - Preview

#Preview("Prompt Configuration") {
    PromptConfigView()
        .frame(width: 700, height: 500)
}
