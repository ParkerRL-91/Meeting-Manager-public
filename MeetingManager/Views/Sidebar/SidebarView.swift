import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""

    private var filteredUpcoming: [Meeting] {
        if searchQuery.isEmpty {
            return appState.upcomingMeetings
        }
        return appState.upcomingMeetings.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var filteredPast: [Meeting] {
        if searchQuery.isEmpty {
            return appState.pastMeetings
        }
        return appState.pastMeetings.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var hasNoResults: Bool {
        !searchQuery.isEmpty && filteredUpcoming.isEmpty && filteredPast.isEmpty
    }

    private var hasNoMeetings: Bool {
        searchQuery.isEmpty && appState.upcomingMeetings.isEmpty && appState.pastMeetings.isEmpty
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            // MARK: - Header

            VStack(spacing: 10) {
                Button {
                    createAdHocMeeting()
                } label: {
                    Label("New Meeting", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .controlSize(.large)

                SearchBar(query: $searchQuery, placeholder: "Search meetings...")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // MARK: - Meeting List

            if hasNoMeetings {
                Spacer()
                EmptyStateView(
                    icon: "calendar.badge.plus",
                    title: "No Meetings",
                    subtitle: "Start a new meeting or connect your calendar to see upcoming events."
                )
                .padding()
                Spacer()
            } else if hasNoResults {
                Spacer()
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No Results",
                    subtitle: "No meetings match \"\(searchQuery)\". Try a different search term."
                )
                .padding()
                Spacer()
            } else {
                List(selection: $appState.selectedMeetingId) {
                    if !filteredUpcoming.isEmpty {
                        Section("Upcoming") {
                            ForEach(filteredUpcoming) { meeting in
                                MeetingListRow(meeting: meeting)
                                    .tag(meeting.id)
                            }
                        }
                    } else if searchQuery.isEmpty {
                        Section("Upcoming") {
                            Text("No upcoming meetings")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        }
                    }

                    if !filteredPast.isEmpty {
                        Section("Past") {
                            ForEach(filteredPast) { meeting in
                                MeetingListRow(meeting: meeting)
                                    .tag(meeting.id)
                            }
                        }
                    } else if searchQuery.isEmpty {
                        Section("Past") {
                            Text("No past meetings")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color.appBackground)
        .onAppear {
            appState.loadMeetings()
        }
    }

    // MARK: - Actions

    private func createAdHocMeeting() {
        Task {
            do {
                let meeting = try await appState.stateMachine.createAndStartMeeting(title: "New Meeting")
                appState.activeMeeting = meeting
                appState.isRecording = true
                appState.selectedMeetingId = meeting.id
                appState.loadMeetings()
            } catch {
                print("Failed to create meeting: \(error)")
            }
        }
    }
}

// MARK: - Previews

#Preview("With Meetings") {
    SidebarView()
        .environment(AppState())
        .frame(width: 300, height: 600)
}

#Preview("Empty State") {
    SidebarView()
        .environment(AppState())
        .frame(width: 300, height: 600)
}
