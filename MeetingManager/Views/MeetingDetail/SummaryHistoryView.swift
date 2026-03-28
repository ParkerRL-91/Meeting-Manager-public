import SwiftUI

struct SummaryHistoryView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var summaries: [MeetingSummary] = []
    @State private var isLoading = true
    @State private var selectedSummary: MeetingSummary?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Summary History")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)

            Divider()
                .foregroundStyle(Color.appSeparator)

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if summaries.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "No History",
                    subtitle: "Past summaries will appear here."
                )
                Spacer()
            } else {
                List(selection: $selectedSummary) {
                    ForEach(summaries) { summary in
                        SummaryHistoryRow(summary: summary, isSelected: selectedSummary?.id == summary.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation {
                                    if selectedSummary?.id == summary.id {
                                        selectedSummary = nil
                                    } else {
                                        selectedSummary = summary
                                    }
                                }
                            }
                            .listRowBackground(Color.appSurface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                if let selected = selectedSummary {
                    Divider()
                        .foregroundStyle(Color.appSeparator)

                    ScrollView {
                        Text(selected.summaryText)
                            .font(.body)
                            .foregroundStyle(Color.appTextPrimary)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .frame(maxHeight: 300)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color.appBackground)
        .task {
            await loadHistory()
        }
    }

    private func loadHistory() async {
        isLoading = true
        defer { isLoading = false }
        summaries = (try? await appState.summaryRepository.allSummaries(meetingId: meetingId)) ?? []
    }
}

// MARK: - Summary History Row

private struct SummaryHistoryRow: View {
    let summary: MeetingSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(DateFormatting.fullDateTime(from: summary.generatedAt))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.appTextPrimary)

                    if summary.isEdited {
                        Text("Edited")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appWarning)
                            .clipShape(Capsule())
                    } else {
                        Text("AI Generated")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appAccent)
                            .clipShape(Capsule())
                    }
                }

                if let model = summary.modelUsed {
                    Label(model, systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }

            Spacer()

            Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    SummaryHistoryView(meetingId: "preview-1")
        .environment(AppState())
        .frame(width: 600, height: 500)
}
