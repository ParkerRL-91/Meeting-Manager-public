import SwiftUI

/// People directory extracted from meeting participants across all meetings.
/// Shows each unique person with their meeting history.
struct PeopleView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""
    @State private var selectedPerson: PersonEntry?

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - People List
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("People")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                        Text("\(filteredPeople.count) contacts")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 12)

                // Search
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextTertiary)
                    TextField("Search people…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                Divider().background(Color.appSeparator)

                if filteredPeople.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "person.2.slash")
                            .font(.largeTitle)
                            .foregroundStyle(Color.appTextTertiary)
                        Text(searchQuery.isEmpty ? "No people found" : "No results for \"\(searchQuery)\"")
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                        if searchQuery.isEmpty {
                            Text("Participants will appear here once you\nhave meetings with named attendees.")
                                .font(.caption)
                                .foregroundStyle(Color.appTextTertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredPeople) { person in
                                PersonRow(person: person, isSelected: selectedPerson?.id == person.id)
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            selectedPerson = person
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(width: 280)
            .background(Color.appBackground)

            Divider().background(Color.appSeparator)

            // MARK: - Person Detail
            if let person = selectedPerson {
                PersonDetailView(person: person)
                    .id(person.id)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.appTextTertiary)
                    Text("Select a person")
                        .font(.title3)
                        .foregroundStyle(Color.appTextSecondary)
                    Text("View their meeting history and notes")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
            }
        }
        .background(Color.appBackground)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: appState.meetings) { selectFirstIfNeeded() }
    }

    // MARK: - Computed

    private var allPeople: [PersonEntry] {
        appState.allPeople().map { pair in
            PersonEntry(
                name: pair.name,
                meetings: pair.meetings.sorted {
                    ($0.effectiveDate) > ($1.effectiveDate)
                }
            )
        }
    }

    private var filteredPeople: [PersonEntry] {
        guard !searchQuery.isEmpty else { return allPeople }
        return allPeople.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private func selectFirstIfNeeded() {
        if selectedPerson == nil, let first = filteredPeople.first {
            selectedPerson = first
        }
    }
}

// MARK: - PersonEntry Model

struct PersonEntry: Identifiable {
    var id: String { name }
    let name: String
    let meetings: [Meeting]

    var meetingCount: Int { meetings.count }
    var lastMeetingDate: Date? { meetings.first?.effectiveDate }

    var initials: String {
        let parts = name.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1)) + String(parts[1].prefix(1))
        }
        return String(name.prefix(2)).uppercased()
    }
}

// MARK: - Person Row

private struct PersonRow: View {
    let person: PersonEntry
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            InitialsAvatar(name: person.name, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text("\(person.meetingCount) meeting\(person.meetingCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)

                    if let date = person.lastMeetingDate {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                        Text(relativeDateShort(date))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.appAccent.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func relativeDateShort(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Person Detail View

private struct PersonDetailView: View {
    let person: PersonEntry
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Profile header
                VStack(spacing: 14) {
                    InitialsAvatar(name: person.name, size: 72)

                    VStack(spacing: 4) {
                        Text(person.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)

                        HStack(spacing: 12) {
                            Label("\(person.meetingCount) meetings", systemImage: "calendar")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)

                            if let date = person.lastMeetingDate {
                                Label(date.formatted(date: .abbreviated, time: .omitted),
                                      systemImage: "clock")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)

                Divider()
                    .background(Color.appSeparator)
                    .padding(.horizontal, 24)

                // Meeting history
                VStack(alignment: .leading, spacing: 10) {
                    Text("Meeting History")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .padding(.top, 20)

                    ForEach(person.meetings) { meeting in
                        PersonMeetingRow(meeting: meeting)
                            .onTapGesture {
                                appState.selectedMeetingId = meeting.id
                            }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .background(Color.appBackground)
    }
}

// MARK: - Person Meeting Row

private struct PersonMeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            // Date badge
            VStack(spacing: 1) {
                Text(meeting.effectiveDate.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .textCase(.uppercase)
                Text(meeting.effectiveDate.formatted(.dateTime.day()))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appTextPrimary)
            }
            .frame(width: 36)
            .padding(.vertical, 6)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(meeting.effectiveDate.formatted(.dateTime.hour().minute()))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)

                    let dur = meeting.formattedDuration
                    if dur != "--" {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                        Text(dur)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }

                    // Other attendees
                    let others = meeting.participantList.filter { $0 != /* current person; best-effort */ "" }
                    if others.count > 1 {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                        Text("+\(others.count - 1) others")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }

            Spacer()

            // Status badge
            Image(systemName: meeting.status == .complete ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(meeting.status == .complete ? Color.appSuccess : Color.appTextTertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
