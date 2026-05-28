import SwiftUI
import os

/// Settings panel for third-party integrations. Currently surfaces Apollo
/// (attendee profile prep). Each integration is gated on three things —
/// a feature toggle, a Keychain-stored API key, and a successful "Test"
/// validation — so the UI never claims it's enabled when the key is bad.
///
/// Uses the same `Form { Section { ... } }` / `.formStyle(.grouped)` shape
/// as the rest of the Settings tabs so the chrome lines up.
struct IntegrationsSettingsView: View {

    @Environment(AppState.self) private var appState

    // Apollo
    @State private var apolloKey: String = ""
    @State private var showApolloKey: Bool = false
    @State private var isTestingApollo: Bool = false
    @State private var apolloTestMessage: String?
    @State private var apolloTestError: String?

    var body: some View {
        @Bindable var appState = appState
        Form {
            apolloToggleSection
            apolloKeySection
                .disabled(!appState.settings.apolloProfilePrepEnabled)
                .opacity(appState.settings.apolloProfilePrepEnabled ? 1 : 0.5)
            apolloStatusSection
                .disabled(!appState.settings.apolloProfilePrepEnabled)
                .opacity(appState.settings.apolloProfilePrepEnabled ? 1 : 0.5)
        }
        .formStyle(.grouped)
        .onAppear { loadApolloKey() }
    }

    // MARK: - Sections

    private var apolloToggleSection: some View {
        @Bindable var appState = appState
        return Section {
            Toggle("Integrated Attendee Profile Prep", isOn: $appState.settings.apolloProfilePrepEnabled)
            if appState.settings.apolloProfilePrepEnabled {
                Text("Replaces the Context card in the meeting view and pre-meeting prep with attendee profiles: title, employer, recent moves, and a LinkedIn link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Off — meeting views show the existing AI Context card from past meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Apollo.io")
        }
    }

    private var apolloKeySection: some View {
        Section {
            HStack {
                Group {
                    if showApolloKey {
                        TextField("Apollo API key", text: $apolloKey)
                    } else {
                        SecureField("Apollo API key", text: $apolloKey)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    showApolloKey.toggle()
                } label: {
                    Image(systemName: showApolloKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(showApolloKey ? "Hide API key" : "Show API key")
            }

            HStack {
                Button("Save API Key") {
                    saveApolloKey()
                }
                .disabled(apolloKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await testApolloKey() }
                } label: {
                    if isTestingApollo {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(isTestingApollo || apolloKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                apolloTestBadge
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Your key is stored securely in the macOS Keychain. Get a key at [apollo.io](https://app.apollo.io/#/settings/integrations/api/keys).")
        }
    }

    @ViewBuilder
    private var apolloTestBadge: some View {
        if let msg = apolloTestMessage {
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.appSuccess)
                .font(.caption)
        } else if let err = apolloTestError {
            Label(err, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        } else if appState.settings.apolloKeyValidated,
                  let when = appState.settings.apolloKeyLastValidatedAt {
            Label("Verified \(when, format: .relative(presentation: .named))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.appSuccess)
                .font(.caption)
        } else {
            EmptyView()
        }
    }

    private var apolloStatusSection: some View {
        let conditions: [(String, Bool)] = [
            ("Toggle enabled", appState.settings.apolloProfilePrepEnabled),
            ("API key stored", !apolloKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            ("Key validated by Test", appState.settings.apolloKeyValidated)
        ]
        let allMet = conditions.allSatisfy { $0.1 }
        return Section {
            ForEach(conditions, id: \.0) { name, met in
                HStack {
                    Image(systemName: met ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(met ? Color.appSuccess : .secondary)
                    Text(name)
                    Spacer()
                }
            }
        } header: {
            Text("Surface in meeting views")
        } footer: {
            Text(allMet
                 ? "Attendee Profile section is live. The Context card has been replaced in the meeting view and pre-meeting prep."
                 : "All three conditions must be true for the Attendee Profile section to surface in meeting views.")
                .foregroundStyle(allMet ? Color.appSuccess : .secondary)
        }
    }

    // MARK: - Key plumbing

    private func loadApolloKey() {
        apolloKey = (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.apolloAPIKey)) ?? ""
    }

    private func saveApolloKey() {
        let trimmed = apolloKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try KeychainHelper.delete(forKey: KeychainHelper.Key.apolloAPIKey)
            } else {
                try KeychainHelper.save(trimmed, forKey: KeychainHelper.Key.apolloAPIKey)
            }
        } catch {
            apolloTestError = "Couldn't save key: \(error.localizedDescription)"
            return
        }
        // A new key invalidates the last test result — the user has to
        // re-run Test before the section will surface again.
        appState.settings.apolloKeyValidated = false
        appState.settings.apolloKeyLastValidatedAt = nil
        apolloTestMessage = nil
        apolloTestError = nil
        ApolloService.shared.clearCache()
    }

    private func testApolloKey() async {
        let trimmed = apolloKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isTestingApollo = true
        apolloTestMessage = nil
        apolloTestError = nil

        // Make sure the key is actually saved so subsequent lookupPerson
        // calls find it in the Keychain.
        try? KeychainHelper.save(trimmed, forKey: KeychainHelper.Key.apolloAPIKey)

        do {
            _ = try await ApolloService.shared.validate(apiKey: trimmed)
            appState.settings.apolloKeyValidated = true
            appState.settings.apolloKeyLastValidatedAt = Date()
            apolloTestMessage = "Connected to Apollo successfully."
        } catch {
            appState.settings.apolloKeyValidated = false
            appState.settings.apolloKeyLastValidatedAt = nil
            apolloTestError = error.localizedDescription
        }

        isTestingApollo = false
    }
}
