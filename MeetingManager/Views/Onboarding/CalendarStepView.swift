import SwiftUI

struct CalendarStepView: View {
    /// Called when the user finishes the step — either by skipping it
    /// outright or by successfully connecting a calendar. Bound to
    /// `OnboardingManager.nextStep` from the parent view. Non-optional so a
    /// successful Apple grant can never silently strand the user.
    let onAdvance: () -> Void

    /// Use the shared `GoogleAuthManager` from AppState so the same instance
    /// drives the running `CalendarSyncManager` after onboarding finishes.
    @Environment(AppState.self) private var appState
    private var authManager: GoogleAuthManager { appState.googleAuthManager }
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var isConnectingApple = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(Color.appAccent)

            Text("Connect a calendar")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Connect Google Calendar or Apple Calendar to automatically detect upcoming meetings and sync event details. You can change this later in Settings.")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            VStack(spacing: 16) {
                if authManager.isSignedIn {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.appSuccess)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected")
                                .font(.headline)
                                .foregroundStyle(Color.appTextPrimary)

                            if let email = authManager.userEmail {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                        }

                        Spacer()

                        Button("Disconnect") {
                            authManager.signOut()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    Button {
                        connectCalendar()
                    } label: {
                        HStack(spacing: 8) {
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "link")
                            }
                            Text("Connect Google Calendar")
                        }
                        .frame(maxWidth: 280)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .disabled(isConnecting)

                    if let error = connectionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.appWarning)
                    }
                }
            }
            .padding(20)
            .background(Color.appSurface)
            .cornerRadius(12)
            .frame(maxWidth: 400)

            Text("You can skip this and connect later in Settings.")
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)

            // Apple Calendar option — uses EventKit and works with iCloud,
            // local, Exchange, and Outlook-on-macOS calendars.
            Button {
                connectAppleCalendar()
            } label: {
                HStack(spacing: 8) {
                    if isConnectingApple {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "calendar")
                    }
                    Text("Use Apple Calendar")
                }
                .frame(maxWidth: 280)
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(isConnectingApple)

            Button("Set up later", action: onAdvance)
                .buttonStyle(.bordered)
                .controlSize(.regular)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectCalendar() {
        isConnecting = true
        connectionError = nil

        Task {
            do {
                try await authManager.signIn()
                // Default source is .googleCalendar already, but signing in
                // mid-session needs to nudge the running sync manager so the
                // first sync isn't deferred until the next periodic tick.
                NotificationCenter.default.post(name: .calendarSourceChanged, object: nil)
            } catch {
                connectionError = "Connection failed: \(error.localizedDescription)"
            }
            isConnecting = false
        }
    }

    private func connectAppleCalendar() {
        isConnectingApple = true
        connectionError = nil

        Task {
            let granted = await AppleCalendarService.shared.requestAccess()
            isConnectingApple = false
            if granted {
                UserDefaults.standard.set("appleCalendar", forKey: "calendar.source")
                // Tell the running CalendarSyncManager (in AppState) to start
                // pulling Apple events immediately rather than waiting for the
                // next launch.
                NotificationCenter.default.post(name: .calendarSourceChanged, object: nil)
                onAdvance()
            } else {
                connectionError = "Apple Calendar access was not granted. You can enable it later in System Settings > Privacy & Security > Calendars."
            }
        }
    }
}
