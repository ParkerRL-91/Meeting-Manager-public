import SwiftUI

/// Settings panel for third-party integrations. Currently surfaces Apollo
/// (attendee profile prep). Each integration is gated on three things —
/// a feature toggle, a Keychain-stored API key, and a successful "Test"
/// validation — so the UI never claims it's enabled when the key is bad.
struct IntegrationsSettingsView: View {

    @Environment(AppState.self) private var appState

    // Apollo
    @State private var apolloKey: String = ""
    @State private var apolloKeyMasked: Bool = true
    @State private var isTestingApollo: Bool = false
    @State private var apolloTestMessage: String?
    @State private var apolloTestError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                apolloSection
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Color.appBackground)
        .task { loadApolloKey() }
    }

    // MARK: - Apollo

    private var apolloSection: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Integrated Attendee Profile Prep")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    Text("Powered by Apollo.io. Surfaces title, employer, recent moves, and LinkedIn for everyone on the invite list.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.appTextSecondary)
                }
                Spacer()
            }

            Toggle(isOn: $state.settings.apolloProfilePrepEnabled) {
                Text("Show attendee profile section in meeting view and pre-meeting prep")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Apollo API Key")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                    Spacer()
                    Button(apolloKeyMasked ? "Show" : "Hide") {
                        apolloKeyMasked.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                }

                if apolloKeyMasked {
                    SecureField("Paste your Apollo API key", text: $apolloKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("Paste your Apollo API key", text: $apolloKey)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    Button {
                        saveApolloKey()
                    } label: {
                        Text("Save key")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .disabled(apolloKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task { await testApolloKey() }
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingApollo {
                                ProgressView().controlSize(.mini)
                            }
                            Text(isTestingApollo ? "Testing…" : "Test")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(minWidth: 70)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTestingApollo || apolloKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let msg = apolloTestMessage {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appSuccess)
                    }
                    if let err = apolloTestError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appRecording)
                    }
                    Spacer()
                }

                if appState.settings.apolloKeyValidated,
                   let lastValidated = appState.settings.apolloKeyLastValidatedAt {
                    Text("Key verified \(lastValidated, format: .relative(presentation: .named)).")
                        .font(.caption2)
                        .foregroundStyle(Color.appSuccess)
                } else if !apolloKey.isEmpty {
                    Text("Key not yet verified. Click Test to confirm Apollo accepts it.")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextMuted)
                }
            }

            statusCard
        }
        .padding(16)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.appBorderStrong, lineWidth: 1)
        )
    }

    private var statusCard: some View {
        let conditions: [(String, Bool)] = [
            ("Toggle enabled", appState.settings.apolloProfilePrepEnabled),
            ("API key stored", !apolloKey.isEmpty),
            ("Key validated by Test", appState.settings.apolloKeyValidated)
        ]
        let allMet = conditions.allSatisfy { $0.1 }
        return VStack(alignment: .leading, spacing: 6) {
            Text(allMet ? "Attendee Profile section is live in meetings." : "Attendee Profile section is hidden until all three are true:")
                .font(.caption.weight(.medium))
                .foregroundStyle(allMet ? Color.appSuccess : Color.appTextSecondary)
            ForEach(conditions, id: \.0) { name, met in
                HStack(spacing: 6) {
                    Image(systemName: met ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(met ? Color.appSuccess : Color.appTextMuted)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Key plumbing

    private func loadApolloKey() {
        apolloKey = (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.apolloAPIKey)) ?? ""
    }

    private func saveApolloKey() {
        let trimmed = apolloKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? KeychainHelper.delete(forKey: KeychainHelper.Key.apolloAPIKey)
        } else {
            try? KeychainHelper.save(trimmed, forKey: KeychainHelper.Key.apolloAPIKey)
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
