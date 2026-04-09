import SwiftUI

/// Search view with a date picker calendar and text search for finding meetings.
/// Replaces the meeting list that was removed from the sidebar.
struct MeetingSearchView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""
    @State private var selectedDate: Date? = nil
    @State private var results: [Meeting] = []
    @State private var isLoading = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            HStack {
                Text("Search Meetings")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                if selectedDate != nil || !searchQuery.isEmpty {
                    Button("Clear All") {
                        searchQuery = ""
                        selectedDate = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.appAccent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // MARK: - Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.appTextTertiary)
                TextField("Search by meeting name...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.appSurfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // MARK: - Calendar + Results split
            HStack(alignment: .top, spacing: 0) {
                // Calendar Picker
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Pick a Date")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.appTextSecondary)
                        Spacer()
                        if selectedDate != nil {
                            Button("Clear") {
                                selectedDate = nil
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.appAccent)
                        }
                    }
                    .padding(.horizontal, 4)

                    DatePicker(
                        "Date",
                        selection: Binding(
                            get: { selectedDate ?? Date() },
                            set: { selectedDate = $0 }
                        ),
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .tint(Color.appAccent)
                }
                .frame(width: 280)
                .padding(.horizontal, 20)
                .padding(.top, 4)

                Divider()

                // Results
                VStack(alignment: .leading, spacing: 0) {
                    // Results header
                    HStack {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                            Text("Searching...")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                        } else {
                            Text(resultsTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider()

                    if results.isEmpty && !isLoading {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundStyle(Color.appTextTertiary)
                            Text(emptyStateTitle)
                                .font(.headline)
                                .foregroundStyle(Color.appTextSecondary)
                            Text(emptyStateSubtitle)
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(results) { meeting in
                                    SearchResultRow(meeting: meeting) {
                                        appState.selectedMeetingId = meeting.id
                                        appState.sidebarDestination = .meetings
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .background(Color.appBackground)
        .onAppear {
            isSearchFocused = true
            performSearch()
        }
        .onChange(of: searchQuery) { _, _ in performSearch() }
        .onChange(of: selectedDate) { _, _ in performSearch() }
    }

    // MARK: - Search Logic

    private func performSearch() {
        isLoading = true
        Task {
            let query = searchQuery.isEmpty ? nil : searchQuery
            let date = selectedDate
            let found = (try? await appState.meetingRepository.search(query: query, date: date)) ?? []
            await MainActor.run {
                results = found
                isLoading = false
            }
        }
    }

    // MARK: - Display Helpers

    private var resultsTitle: String {
        if searchQuery.isEmpty && selectedDate == nil {
            return "\(results.count) recent meetings"
        }
        return "\(results.count) result\(results.count == 1 ? "" : "s")"
    }

    private var emptyStateTitle: String {
        if searchQuery.isEmpty && selectedDate == nil {
            return "No Meetings Yet"
        }
        return "No Results"
    }

    private var emptyStateSubtitle: String {
        if searchQuery.isEmpty && selectedDate == nil {
            return "Start a new meeting or connect your calendar."
        }
        if selectedDate != nil && !searchQuery.isEmpty {
            return "No meetings match \"\(searchQuery)\" on the selected date."
        }
        if selectedDate != nil {
            return "No meetings on the selected date."
        }
        return "No meetings match \"\(searchQuery)\". Try a different search term."
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let meeting: Meeting
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Date badge
                VStack(spacing: 0) {
                    Text(meeting.effectiveDate.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                    Text(meeting.effectiveDate.formatted(.dateTime.day()))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.appTextPrimary)
                }
                .frame(width: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        // Time
                        Text(meeting.effectiveDate.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)

                        // Duration
                        if meeting.duration != nil {
                            Text("·")
                                .foregroundStyle(Color.appTextTertiary)
                            Text(meeting.formattedDuration)
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }

                        // Participant count
                        if !meeting.participantList.isEmpty {
                            Text("·")
                                .foregroundStyle(Color.appTextTertiary)
                            HStack(spacing: 3) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 9))
                                Text("\(meeting.participantList.count)")
                                    .font(.caption)
                            }
                            .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                }

                Spacer()

                // Status
                SearchStatusBadge(status: meeting.status)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status Badge

private struct SearchStatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        Text(status.displayLabel)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(status.badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.badgeColor.opacity(0.12))
            .clipShape(Capsule())
    }
}

private extension MeetingStatus {
    var displayLabel: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .notified: return "Starting"
        case .recording: return "Recording"
        case .transcribing: return "Processing"
        case .summarizing: return "Summarizing"
        case .complete: return "Complete"
        case .archived: return "Archived"
        case .cancelled: return "Cancelled"
        }
    }

    var badgeColor: Color {
        switch self {
        case .recording: return Color.appRecording
        case .complete: return .green
        case .archived: return Color.appTextTertiary
        case .cancelled: return Color.appTextTertiary
        case .scheduled, .notified: return Color.appAccent
        case .transcribing, .summarizing: return .orange
        }
    }
}
