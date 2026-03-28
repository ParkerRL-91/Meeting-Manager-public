import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct MeetingDetailView: View {
    let meetingId: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var meeting: Meeting?
    @State private var selectedTab: DetailTab = .summary
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false

    private let exportService = ExportService()

    enum DetailTab: String, CaseIterable {
        case summary, transcript, notes, actionItems

        var label: String {
            switch self {
            case .actionItems: return "Action Items"
            default: return rawValue.capitalized
            }
        }

        var icon: String {
            switch self {
            case .summary: return "doc.text"
            case .transcript: return "text.quote"
            case .notes: return "note.text"
            case .actionItems: return "checklist"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let meeting {
                MeetingMetadataHeader(meeting: meeting, onEdit: {
                    showingEditor = true
                })

                Picker("Tab", selection: $selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Label(tab.label, systemImage: tab.icon)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .foregroundStyle(Color.appSeparator)

                switch selectedTab {
                case .summary:
                    SummaryView(meetingId: meetingId)
                case .transcript:
                    FullTranscriptView(meetingId: meetingId)
                case .notes:
                    NotesReviewView(meetingId: meetingId)
                case .actionItems:
                    ActionItemsView(meetingId: meetingId)
                }
            } else {
                Spacer()
                ProgressView("Loading meeting...")
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let meeting {
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Edit", systemImage: "pencil.circle")
                    }
                    .help("Edit meeting")

                    if meeting.status == .archived {
                        Button {
                            unarchiveMeeting()
                        } label: {
                            Label("Unarchive", systemImage: "archivebox")
                        }
                        .help("Unarchive meeting")
                    } else if !meeting.status.isActive {
                        Button {
                            archiveMeeting()
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .help("Archive meeting")
                    }

                    if meeting.status == .scheduled {
                        Button {
                            cancelMeeting()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .help("Cancel meeting")
                    }

                    Menu {
                        Button("Summary (Markdown)") { Task { await exportSummary() } }
                        Button("Transcript (Text)") { Task { await exportTranscript() } }
                        Button("Full Report (Markdown)") { Task { await exportFullReport() } }
                        Divider()
                        Button("Copy Summary as Markdown") { copySummaryMarkdown() }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export meeting")

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete meeting")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            if let meeting {
                MeetingEditorSheet(meeting: meeting) { title, startDate, endDate in
                    saveMeetingEdits(title: title, startDate: startDate, endDate: endDate)
                }
            }
        }
        .confirmationDialog(
            "Delete Meeting",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteMeeting()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this meeting? This will also delete all associated transcripts, notes, and summaries. This action cannot be undone.")
        }
        .task {
            meeting = try? await appState.meetingRepository.find(id: meetingId)
        }
    }

    // MARK: - Actions

    private func saveMeetingEdits(title: String, startDate: Date?, endDate: Date?) {
        guard var updatedMeeting = meeting else { return }
        updatedMeeting.title = title
        updatedMeeting.scheduledStartDate = startDate
        updatedMeeting.scheduledEndDate = endDate

        Task {
            do {
                try await appState.meetingRepository.update(updatedMeeting)
                meeting = updatedMeeting
                appState.loadMeetings()
            } catch {
                print("Failed to update meeting: \(error)")
            }
        }
    }

    private func archiveMeeting() {
        Task {
            do {
                try await appState.meetingRepository.archive(id: meetingId)
                meeting?.status = .archived
                appState.loadMeetings()
            } catch {
                print("Failed to archive meeting: \(error)")
            }
        }
    }

    private func unarchiveMeeting() {
        Task {
            do {
                try await appState.meetingRepository.unarchive(id: meetingId)
                meeting?.status = .complete
                appState.loadMeetings()
            } catch {
                print("Failed to unarchive meeting: \(error)")
            }
        }
    }

    private func cancelMeeting() {
        guard var updatedMeeting = meeting else { return }
        updatedMeeting.status = .cancelled

        Task {
            do {
                try await appState.meetingRepository.update(updatedMeeting)
                meeting = updatedMeeting
                appState.loadMeetings()
            } catch {
                print("Failed to cancel meeting: \(error)")
            }
        }
    }

    // MARK: - Export Actions

    private func exportSummary() async {
        guard let meeting else { return }
        guard let summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId) else { return }
        let content = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
        let filename = ExportService.sanitizedFilename(from: meeting.title) + "-summary.md"
        _ = await exportService.saveToFile(content: content, suggestedName: filename, fileType: "md")
    }

    private func exportTranscript() async {
        guard let meeting else { return }
        let transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
        let content = exportService.exportTranscriptText(meeting: meeting, transcripts: transcripts)
        let filename = ExportService.sanitizedFilename(from: meeting.title) + "-transcript.txt"
        _ = await exportService.saveToFile(content: content, suggestedName: filename, fileType: "txt")
    }

    private func exportFullReport() async {
        guard let meeting else { return }
        let summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId)
        let transcripts = (try? await appState.transcriptRepository.transcriptsForMeeting(meetingId)) ?? []
        let notes = (try? await appState.noteRepository.notesForMeeting(meetingId)) ?? []
        let content = exportService.exportFullReport(meeting: meeting, summary: summary, transcripts: transcripts, notes: notes)
        let filename = ExportService.sanitizedFilename(from: meeting.title) + "-report.md"
        _ = await exportService.saveToFile(content: content, suggestedName: filename, fileType: "md")
    }

    private func copySummaryMarkdown() {
        guard let meeting else { return }
        Task {
            guard let summary = try? await appState.summaryRepository.latestSummary(meetingId: meetingId) else { return }
            let markdown = exportService.exportSummaryMarkdown(meeting: meeting, summary: summary)
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            #endif
        }
    }

    private func deleteMeeting() {
        guard let meeting else { return }
        Task {
            do {
                try await appState.meetingRepository.delete(meeting)
                appState.selectedMeetingId = nil
                appState.loadMeetings()
            } catch {
                print("Failed to delete meeting: \(error)")
            }
        }
    }
}

// MARK: - Preview

#Preview("Detail View") {
    MeetingDetailView(meetingId: "preview-1")
        .environment(AppState())
        .frame(width: 600, height: 700)
}
