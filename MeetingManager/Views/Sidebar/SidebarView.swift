import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""
    @State private var showArchived = false
    @State private var showAllActionItems = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool

    private var filteredUpcoming: [Meeting] {
        let base = showArchived
            ? appState.upcomingMeetings
            : appState.upcomingMeetings.filter { $0.status != .archived }
        if searchQuery.isEmpty {
            return base
        }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var filteredPast: [Meeting] {
        let base = showArchived
            ? appState.pastMeetings
            : appState.pastMeetings.filter { $0.status != .archived }
        if searchQuery.isEmpty {
            return base
        }
        return base.filter {
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
                    .focused($isSearchFocused)

                HStack {
                    Toggle(isOn: $showArchived) {
                        Label("Show Archived", systemImage: "archivebox")
                            .font(.subheadline)
                    }
                    .toggleStyle(.checkbox)

                    Spacer()

                    Button {
                        showAllActionItems = true
                    } label: {
                        Label("Action Items", systemImage: "checklist")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }
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
                                MeetingListRow(meeting: meeting, onError: { errorMessage = $0 })
                                    .tag(meeting.id)
                                    .contextMenu {
                                        if meeting.status == .scheduled || meeting.status == .notified {
                                            Button {
                                                startEarly(meeting)
                                            } label: {
                                                Label("Start Early", systemImage: "play.fill")
                                            }
                                        }
                                    }
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
                                MeetingListRow(meeting: meeting, onError: { errorMessage = $0 })
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
        .errorAlert($errorMessage)
        .sheet(isPresented: $showAllActionItems) {
            AllActionItemsView()
                .environment(appState)
                .frame(minWidth: 500, minHeight: 400)
        }
        .onAppear {
            appState.loadMeetings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewMeeting)) { _ in
            createAdHocMeeting()
        }
    }

    // MARK: - Actions

    private func startEarly(_ meeting: Meeting) {
        appState.startRecording(for: meeting)
    }

    private func createAdHocMeeting() {
        Task {
            do {
                let meeting = try await appState.stateMachine.createAndStartMeeting(title: "New Meeting")
                appState.activeMeeting = meeting
                appState.isRecording = true
                appState.selectedMeetingId = meeting.id
                appState.loadMeetings()
            } catch {
                errorMessage = "Failed to create meeting: \(error.localizedDescription)"
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
