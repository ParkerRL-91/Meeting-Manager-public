import SwiftUI

/// Full-screen search view. Calendar takes the top half; meeting list fills the bottom.
/// Typing in the search bar replaces the date-filtered list with search results.
struct MeetingSearchView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""
    @State private var selectedDate: Date = Date()
    @State private var displayedMonth: Date = Date()
    @State private var results: [Meeting] = []
    @State private var isLoading = false
    @State private var isSearching = false  // true when user is typing a search query
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Search Bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.body)
                    .foregroundStyle(Color.appTextTertiary)
                TextField("Search meetings...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isSearchFocused)
                if isSearching {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            searchQuery = ""
                            isSearching = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // MARK: - Calendar (top half) — hidden when searching
            if !isSearching {
                calendarSection
            }

            Divider()
                .padding(.horizontal, 20)

            // MARK: - Meeting list (bottom half)
            meetingListSection
        }
        .background(Color.appBackground)
        .onAppear { loadMeetingsForDate() }
        .onChange(of: searchQuery) { _, newValue in
            if newValue.isEmpty {
                isSearching = false
                loadMeetingsForDate()
            } else {
                isSearching = true
                performSearch()
            }
        }
        .onChange(of: selectedDate) { _, _ in
            if !isSearching { loadMeetingsForDate() }
        }
    }

    // MARK: - Calendar Section

    private var calendarSection: some View {
        VStack(spacing: 0) {
            // Month navigation
            HStack {
                Button {
                    withAnimation { displayedMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)

                Spacer()

                HStack(spacing: 12) {
                    Button("Today") {
                        withAnimation {
                            displayedMonth = Date()
                            selectedDate = Date()
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appAccent)
                    .buttonStyle(.plain)

                    Button {
                        withAnimation { displayedMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            // Day-of-week headers
            let weekdays = Calendar.current.shortWeekdaySymbols
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 6)

            // Calendar grid
            let days = calendarDays(for: displayedMonth)
            let rows = days.chunked(into: 7)

            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            CalendarDayCell(
                                day: day,
                                displayedMonth: displayedMonth,
                                isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDate),
                                isToday: Calendar.current.isDateInToday(day)
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedDate = day
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Meeting List Section

    private var meetingListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if isSearching {
                    Text("Results for \"\(searchQuery)\"")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                } else {
                    Text(selectedDate.formatted(date: .complete, time: .omitted))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                }
                Spacer()
                Text("\(results.count) meeting\(results.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

            if isLoading {
                Spacer()
                ProgressView()
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if results.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: isSearching ? "doc.text.magnifyingglass" : "calendar")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.appTextTertiary)
                    Text(isSearching ? "No matches" : "No meetings")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { meeting in
                            SearchResultRow(meeting: meeting) {
                                appState.selectedMeetingId = meeting.id
                                appState.sidebarDestination = .meetings
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadMeetingsForDate() {
        isLoading = true
        Task {
            let found = (try? await appState.meetingRepository.search(date: selectedDate)) ?? []
            await MainActor.run {
                results = found
                isLoading = false
            }
        }
    }

    private func performSearch() {
        isLoading = true
        Task {
            let found = (try? await appState.meetingRepository.search(query: searchQuery)) ?? []
            await MainActor.run {
                results = found
                isLoading = false
            }
        }
    }

    // MARK: - Calendar Helpers

    private func calendarDays(for month: Date) -> [Date] {
        let cal = Calendar.current
        let range = cal.range(of: .day, in: .month, for: month)!
        let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let firstWeekday = cal.component(.weekday, from: firstOfMonth)
        let offset = firstWeekday - cal.firstWeekday
        let paddingBefore = (offset + 7) % 7

        var days: [Date] = []
        for i in 0..<paddingBefore {
            days.append(cal.date(byAdding: .day, value: -(paddingBefore - i), to: firstOfMonth)!)
        }
        for day in range {
            days.append(cal.date(byAdding: .day, value: day - 1, to: firstOfMonth)!)
        }
        let remaining = (7 - days.count % 7) % 7
        if let lastDay = days.last {
            for i in 1...max(remaining, 1) {
                days.append(cal.date(byAdding: .day, value: i, to: lastDay)!)
            }
        }
        return days
    }
}

// MARK: - Calendar Day Cell

private struct CalendarDayCell: View {
    let day: Date
    let displayedMonth: Date
    let isSelected: Bool
    let isToday: Bool
    let action: () -> Void

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(day, equalTo: displayedMonth, toGranularity: .month)
    }

    var body: some View {
        Button(action: action) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 14, weight: isToday ? .bold : .regular, design: .rounded))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        if isSelected { return .white }
        if isToday { return Color.appAccent }
        if !isCurrentMonth { return Color.appTextTertiary.opacity(0.4) }
        return Color.appTextPrimary
    }

    private var backgroundColor: Color {
        if isSelected { return Color.appAccent }
        if isToday { return Color.appAccent.opacity(0.12) }
        return Color.clear
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let meeting: Meeting
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(spacing: 1) {
                    Text(meeting.effectiveDate.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    if meeting.duration != nil {
                        Text(meeting.formattedDuration)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
                .frame(width: 60)

                RoundedRectangle(cornerRadius: 2)
                    .fill(meeting.status == .complete ? Color.appAccent : Color.appAccent.opacity(0.5))
                    .frame(width: 3, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(1)
                    if !meeting.participantList.isEmpty {
                        Text("\(meeting.participantList.count) attendee\(meeting.participantList.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }

                Spacer()

                SearchStatusBadge(status: meeting.status)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SearchStatusBadge: View {
    let status: MeetingStatus
    var body: some View {
        Text(status.searchLabel)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(status.searchColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.searchColor.opacity(0.12))
            .clipShape(Capsule())
    }
}

private extension MeetingStatus {
    var searchLabel: String {
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
    var searchColor: Color {
        switch self {
        case .recording: return Color.appRecording
        case .complete: return .green
        case .archived, .cancelled: return Color.appTextTertiary
        case .scheduled, .notified: return Color.appAccent
        case .transcribing, .summarizing: return .orange
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
