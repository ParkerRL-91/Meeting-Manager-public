import SwiftUI
import GRDB
import os

/// Settings view for connecting and configuring Google Calendar integration.
struct GoogleCalendarSettingsView: View {

    // MARK: - Dependencies

    @State private var authManager = GoogleAuthManager()

    // MARK: - State

    /// User-supplied OAuth client ID. Empty = use built-in.
    @State private var oauthClientId: String = ""
    @State private var clientIdSaved = false
    @State private var isSigningIn = false
    @State private var signInError: String?

    // Calendar selection
    @State private var availableCalendars: [(id: String, name: String)] = []
    @State private var selectedCalendarId: String = "primary"
    @State private var isLoadingCalendars = false
    /// True when the most recent calendar fetch returned 401/403, meaning the
    /// stored OAuth token doesn't grant calendar access any more (revoked,
    /// scope mismatch, or expired refresh token). UI surfaces a Reconnect CTA.
    @State private var calendarAccessRevoked = false

    // Sync
    @State private var isSyncing = false
    @State private var isBackfilling = false
    @State private var syncError: String?
    @State private var syncSuccess: String?
    @State private var lastSyncDate: Date?
    @State private var selectedSyncInterval: Int = AppSettings.default.calendarSyncIntervalMinutes

    // Meetings preview
    @State private var upcomingMeetings: [Meeting] = []
    @State private var pastMeetings: [Meeting] = []

    private let syncIntervals: [(minutes: Int, label: String)] = [
        (5,  "Every 5 minutes"),
        (10, "Every 10 minutes"),
        (15, "Every 15 minutes"),
        (30, "Every 30 minutes"),
    ]

    // MARK: - Body

    var body: some View {
        Form {
            clientIdSection
            connectionSection
            if authManager.isSignedIn {
                calendarPickerSection
                syncSection
                meetingsPreviewSection
            }
        }
        .formStyle(.grouped)
        .onAppear { loadState() }
        .onChange(of: authManager.isSignedIn) { _, signedIn in
            if signedIn { loadCalendars() }
        }
    }

    // MARK: - OAuth Client ID Section

    private var clientIdSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                // Built-in vs custom explanation
                if oauthClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Using the built-in OAuth credentials.", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Using your custom OAuth client ID.", systemImage: "person.badge.key.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }

                HStack(spacing: 8) {
                    TextField("Custom OAuth Client ID (optional)", text: $oauthClientId)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        .autocorrectionDisabled()

                    Button(clientIdSaved ? "Saved ✓" : "Save") {
                        saveClientId()
                    }
                    .disabled(clientIdSaved)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !oauthClientId.isEmpty {
                        Button("Clear", role: .destructive) {
                            oauthClientId = ""
                            try? KeychainHelper.delete(forKey: KeychainHelper.Key.googleOAuthClientId)
                            clientIdSaved = false
                            // Force sign-out since the credentials changed
                            authManager.signOut()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("OAuth Credentials")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Leave blank to use the built-in credentials. To use your own:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("1. Open")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Google Cloud Console") {
                        NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                }
                Text("2. Create an OAuth 2.0 Client ID (Desktop app type)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("3. Paste the Client ID above and tap Save")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveClientId() {
        let trimmed = oauthClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? KeychainHelper.delete(forKey: KeychainHelper.Key.googleOAuthClientId)
        } else {
            try? KeychainHelper.save(trimmed, forKey: KeychainHelper.Key.googleOAuthClientId)
        }
        // Sign out so next sign-in uses the new client ID
        if authManager.isSignedIn { authManager.signOut() }
        clientIdSaved = true
        // Reset "Saved" indicator after 2s
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); clientIdSaved = false }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        Section {
            if authManager.isSignedIn {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected")
                            .font(.headline)
                        if let email = authManager.userEmail {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button("Disconnect", role: .destructive) {
                        authManager.signOut()
                        availableCalendars = []
                        upcomingMeetings = []
                        pastMeetings = []
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect Google Calendar")
                                .font(.headline)
                            Text("Sync events and auto-fill meeting details")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            signIn()
                        } label: {
                            if isSigningIn {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Connecting...")
                                }
                            } else {
                                Label("Connect Google", systemImage: "person.badge.plus")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSigningIn)
                    }
                    .padding(.vertical, 4)

                    if let error = signInError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Google Account")
        } footer: {
            if !authManager.isSignedIn {
                Text("Your browser will open for a secure Google sign-in. No password is stored — only a secure token.")
            }
        }
    }

    // MARK: - Calendar Picker Section

    private var calendarPickerSection: some View {
        Section {
            if isLoadingCalendars {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading calendars…")
                        .foregroundStyle(.secondary)
                }
            } else if calendarAccessRevoked {
                // Specific recovery state — the OAuth token doesn't grant calendar
                // access. Most likely cause is that the user revoked it in their
                // Google account, or it was minted before we requested calendar scope.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.appWarning)
                        Text("Calendar access expired")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("Your Google account is connected, but the saved sign-in no longer grants calendar access. Reconnect to continue syncing meetings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reconnect Google Calendar") {
                        signIn()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            } else if availableCalendars.isEmpty {
                HStack {
                    Text("No calendars found")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload") { loadCalendars() }
                        .buttonStyle(.borderless)
                }
            } else {
                Picker("Calendar", selection: $selectedCalendarId) {
                    ForEach(availableCalendars, id: \.id) { calendar in
                        Text(calendar.name).tag(calendar.id)
                    }
                }
                .onChange(of: selectedCalendarId) { _, newId in
                    persistSetting { $0.selectedCalendarId = newId == "primary" ? nil : newId }
                    Logger.calendar.info("Selected calendar changed to \(newId)")
                }
            }
        } header: {
            Text("Calendar to Sync")
        } footer: {
            Text("Choose which calendar to pull meetings from. Changes apply on the next sync.")
        }
    }

    // MARK: - Sync Section

    private var syncSection: some View {
        Section {
            Picker("Auto-sync", selection: $selectedSyncInterval) {
                ForEach(syncIntervals, id: \.minutes) { interval in
                    Text(interval.label).tag(interval.minutes)
                }
            }
            .onChange(of: selectedSyncInterval) { _, newValue in
                persistSetting { $0.calendarSyncIntervalMinutes = newValue }
            }

            HStack {
                Button {
                    syncNow()
                } label: {
                    if isSyncing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Syncing…")
                        }
                    } else {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isSyncing || isBackfilling)

                Button {
                    backfillFromCalendar()
                } label: {
                    if isBackfilling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Backfilling…")
                        }
                    } else {
                        Label("Re-sync 90 days (incl. participants)", systemImage: "person.2.crop.square.stack")
                    }
                }
                .disabled(isSyncing || isBackfilling)
                .help("Wider-window sync that pulls calendar attendees onto past meetings whose participants are missing. Safe to run any time — never overwrites populated data.")

                Spacer()

                if let success = syncSuccess {
                    Label(success, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let error = syncError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            if let lastSync = lastSyncDate {
                LabeledContent("Last synced") {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text(lastSync, style: .relative)
                        Text("ago")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Sync")
        }
    }

    // MARK: - Meetings Preview Section

    private var meetingsPreviewSection: some View {
        Group {
            if !upcomingMeetings.isEmpty {
                Section {
                    ForEach(upcomingMeetings) { meeting in
                        meetingRow(meeting)
                    }
                } header: {
                    Text("Upcoming (\(upcomingMeetings.count))")
                }
            }

            if !pastMeetings.isEmpty {
                Section {
                    ForEach(pastMeetings) { meeting in
                        meetingRow(meeting)
                    }
                } header: {
                    Text("Recent (\(pastMeetings.count))")
                }
            }

            if upcomingMeetings.isEmpty && pastMeetings.isEmpty {
                Section {
                    Text("No synced meetings yet. Tap Sync Now above.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func meetingRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.secondary)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(1)

                if let date = meeting.scheduledStartDate ?? meeting.startDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func loadState() {
        // Load saved client ID
        oauthClientId = (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.googleOAuthClientId)) ?? ""

        selectedSyncInterval = AppSettings.default.calendarSyncIntervalMinutes
        if let settings = try? AppDatabase.shared.writer.read({ db in
            try AppSettings.fetchOne(db)
        }) {
            selectedSyncInterval = settings.calendarSyncIntervalMinutes
            selectedCalendarId = settings.selectedCalendarId ?? "primary"
        }

        if authManager.isSignedIn {
            loadCalendars()
            refreshMeetings()
        }
    }

    private func loadCalendars() {
        isLoadingCalendars = true
        calendarAccessRevoked = false
        Task {
            do {
                let token = try await authManager.refreshTokenIfNeeded()
                let calendars = try await GoogleCalendarService().listCalendars(accessToken: token)
                // Prepend "Primary" as a convenience alias
                let withPrimary = calendars.contains(where: { $0.id == "primary" })
                    ? calendars
                    : [(id: "primary", name: "Primary Calendar")] + calendars
                availableCalendars = withPrimary
                Logger.calendar.info("Loaded \(calendars.count) calendars")
            } catch GoogleCalendarError.accessRevoked {
                Logger.calendar.error("Calendar access revoked — clearing stale session for clean reconnect")
                calendarAccessRevoked = true
                availableCalendars = []
                // Clear the stale token so the next sign-in is a clean OAuth handshake
                // requesting full calendar scope (rather than re-using whatever scope
                // the old refresh token was minted with).
                authManager.signOut()
            } catch {
                Logger.calendar.error("Failed to load calendars: \(error.localizedDescription)")
            }
            isLoadingCalendars = false
        }
    }

    private func signIn() {
        isSigningIn = true
        signInError = nil
        Task {
            do {
                try await authManager.signIn()
                loadCalendars()
                Logger.calendar.info("Google sign-in completed from settings")
            } catch {
                signInError = error.localizedDescription
                Logger.calendar.error("Google sign-in failed: \(error.localizedDescription)")
            }
            isSigningIn = false
        }
    }

    private func syncNow() {
        isSyncing = true
        syncError = nil
        syncSuccess = nil

        Task {
            do {
                let token = try await authManager.refreshTokenIfNeeded()
                let calendarId = selectedCalendarId == "primary" ? "primary" : selectedCalendarId
                let now = Date()
                let from = Calendar.current.date(byAdding: .day, value: -7, to: now)!
                let to = Calendar.current.date(byAdding: .day, value: 7, to: now)!

                let events = try await GoogleCalendarService().fetchEvents(
                    accessToken: token,
                    from: from,
                    to: to,
                    calendarId: calendarId
                )

                // Upsert into DB
                let repo = MeetingRepository(database: AppDatabase.shared)
                for event in events {
                    var meeting: Meeting
                    if var existing = try await repo.findByCalendarEventId(event.id) {
                        // Never overwrite meetings that are recording or already completed
                        guard existing.status == .scheduled || existing.status == .notified else {
                            continue
                        }
                        existing.title = event.title
                        existing.scheduledStartDate = event.startDate
                        existing.scheduledEndDate = event.endDate
                        meeting = existing
                    } else {
                        meeting = Meeting(
                            title: event.title,
                            scheduledStartDate: event.startDate,
                            scheduledEndDate: event.endDate,
                            status: .scheduled,
                            calendarEventId: event.id
                        )
                    }
                    try await repo.save(&meeting)
                }

                lastSyncDate = Date()
                syncSuccess = "\(events.count) event\(events.count == 1 ? "" : "s") synced"
                refreshMeetings()

                // Clear success message after 4 seconds
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                syncSuccess = nil

            } catch {
                syncError = error.localizedDescription
                Logger.calendar.error("Manual sync failed: \(error.localizedDescription)")
            }
            isSyncing = false
        }
    }

    /// Wide-window calendar resync that backfills participants and meet links
    /// onto already-completed meetings. Routed through CalendarSyncManager
    /// (which has the proper "fill empty fields, never overwrite populated"
    /// semantics in upsertMeeting) rather than this view's own narrower sync.
    private func backfillFromCalendar() {
        isBackfilling = true
        syncError = nil
        syncSuccess = nil

        Task {
            do {
                let manager = CalendarSyncManager(
                    authManager: authManager,
                    meetingRepository: MeetingRepository(database: AppDatabase.shared)
                )
                let count = try await manager.backfillFromCalendar(daysBehind: 90, daysAhead: 30)
                lastSyncDate = Date()
                syncSuccess = "Backfilled from \(count) event\(count == 1 ? "" : "s")"
                refreshMeetings()

                // Reload AppState's in-memory meetings so PeopleView and the
                // sidebar pick up the freshly-attached participants.
                NotificationCenter.default.post(name: .calendarBackfillCompleted, object: nil)

                try? await Task.sleep(nanoseconds: 4_000_000_000)
                syncSuccess = nil
            } catch {
                syncError = error.localizedDescription
                Logger.calendar.error("Backfill failed: \(error.localizedDescription)")
            }
            isBackfilling = false
        }
    }

    private func refreshMeetings() {
        let now = Date()
        do {
            upcomingMeetings = try AppDatabase.shared.writer.read { db in
                try Meeting
                    .filter(sql: "scheduledStartDate > ? OR startDate > ?", arguments: [now, now])
                    .order(sql: "COALESCE(scheduledStartDate, startDate) ASC")
                    .limit(7)
                    .fetchAll(db)
            }
            pastMeetings = try AppDatabase.shared.writer.read { db in
                try Meeting
                    .filter(sql: "(scheduledStartDate < ? OR startDate < ?) AND calendarEventId IS NOT NULL",
                            arguments: [now, now])
                    .order(sql: "COALESCE(scheduledStartDate, startDate) DESC")
                    .limit(7)
                    .fetchAll(db)
            }
        } catch {
            Logger.calendar.error("Failed to load meetings preview: \(error.localizedDescription)")
        }
    }

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
            Logger.calendar.error("Failed to persist setting: \(error.localizedDescription)")
        }
    }
}
