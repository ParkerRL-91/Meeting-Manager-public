import SwiftUI

struct CalendarStepView: View {
    /// Optional callback so the user can skip calendar setup entirely (P2-T01).
    /// Bound to `OnboardingManager.nextStep` from the parent view.
    var onSkip: (() -> Void)? = nil

    @State private var authManager = GoogleAuthManager()
    @State private var isConnecting = false
    @State private var connectionError: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(Color.appAccent)

            Text("Google Calendar")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Connect your Google Calendar to automatically detect upcoming meetings and sync event details.")
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

            if let onSkip {
                Button("Set up later", action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }

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
            } catch {
                connectionError = "Connection failed: \(error.localizedDescription)"
            }
            isConnecting = false
        }
    }
}
