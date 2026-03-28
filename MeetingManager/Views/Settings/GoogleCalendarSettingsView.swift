import SwiftUI
import os

/// Settings view for connecting and configuring Google Calendar integration.
struct GoogleCalendarSettingsView: View {

    // MARK: - Dependencies

    @State private var authManager = GoogleAuthManager()
    @State private var syncManager: CalendarSyncManager?

    // MARK: - State

    @State private var selectedSyncInterval: Int = AppSettings.default.calendarSyncIntervalMinutes
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var signInError: String?

    private let syncIntervals: [(minutes: Int, label: String)] = [
        (5, "Every 5 minutes"),
        (10, "Every 10 minutes"),
        (15, "Every 15 minutes"),
        (30, "Every 30 minutes"),
    ]

    // MARK: - Body

    var body: some View {
        Form {
            connectionSection
            if authManager.isSignedIn {
                syncSection
                statusSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            selectedSyncInterval = AppSettings.default.calendarSyncIntervalMinutes
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        Section {
            if authManager.isSignedIn {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.appSuccess)
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

                    Button("Sign Out", role: .destructive) {
                        authManager.signOut()
                        syncManager?.stopSync()
                        syncManager = nil
                    }
                }
            } else {
                HStack {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Not connected")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        signIn()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.plus")
                            Text("Sign in with Google")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let error = signInError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Google Account")
        } footer: {
            Text("Connect your Google account to automatically sync calendar events as meetings.")
        }
    }

    // MARK: - Sync Section

    private var syncSection: some View {
        Section {
            Picker("Sync Interval", selection: $selectedSyncInterval) {
                ForEach(syncIntervals, id: \.minutes) { interval in
                    Text(interval.label).tag(interval.minutes)
                }
            }
            .onChange(of: selectedSyncInterval) { _, newValue in
                persistSetting { $0.calendarSyncIntervalMinutes = newValue }
                Logger.calendar.info("Sync interval changed to \(newValue) minutes")
                syncManager?.startPeriodicSync(interval: TimeInterval(newValue * 60))
            }

            HStack {
                Button {
                    syncNow()
                } label: {
                    if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                        Text("Syncing...")
                    } else {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isSyncing)

                Spacer()

                if let error = syncError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
        } header: {
            Text("Synchronisation")
        } footer: {
            Text("Events from the past day and next 7 days are synced automatically.")
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section("Status") {
            if let lastSync = syncManager?.lastSyncDate {
                LabeledContent("Last Sync") {
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                    + Text(" ago")
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Last Sync") {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }

            if let count = syncManager?.eventsSyncedCount, count > 0 {
                LabeledContent("Events Synced") {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func signIn() {
        signInError = nil
        Task {
            do {
                try await authManager.signIn()
                Logger.calendar.info("Google sign-in completed from settings")
            } catch {
                signInError = error.localizedDescription
                Logger.calendar.error("Google sign-in failed: \(error.localizedDescription)")
            }
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

    private func syncNow() {
        isSyncing = true
        syncError = nil
        Task {
            do {
                if syncManager == nil {
                    Logger.calendar.debug("SyncManager not available for manual sync")
                    isSyncing = false
                    return
                }
                try await syncManager?.syncNow()
            } catch {
                syncError = error.localizedDescription
                Logger.calendar.error("Manual sync failed: \(error.localizedDescription)")
            }
            isSyncing = false
        }
    }
}

// MARK: - Preview

#Preview("Google Calendar Settings") {
    GoogleCalendarSettingsView()
        .frame(width: 500, height: 400)
}
