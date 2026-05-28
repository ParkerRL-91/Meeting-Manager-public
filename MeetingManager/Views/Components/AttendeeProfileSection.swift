import SwiftUI
import os

/// Replaces the "CONTEXT" card on meeting views when the user has Apollo
/// integration enabled, an API key stored, and validated. Surfaces a small
/// profile card per non-local attendee: title, employer, recent moves,
/// LinkedIn link.
///
/// Looks up each attendee asynchronously on appear. Cached per-session by
/// ApolloService so re-navigating to the same meeting is free. Hides itself
/// silently when no attendees have email addresses we can look up.
struct AttendeeProfileSection: View {
    let participants: [String]
    /// Lowercased email or name of the local user — excluded from lookups.
    let excludeIdentifiers: Set<String>

    @State private var profiles: [String: ApolloService.Profile] = [:]
    @State private var failed: Set<String> = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    /// Persist collapse state across navigation, same pattern as the CONTEXT
    /// card we replace.
    @AppStorage("attendeeProfileExpanded") private var isExpanded: Bool = true

    private var lookupableAttendees: [String] {
        participants.filter { p in
            let lower = p.lowercased().trimmingCharacters(in: .whitespaces)
            guard !lower.isEmpty, lower.contains("@") else { return false }
            return !excludeIdentifiers.contains(lower)
        }
    }

    var body: some View {
        if lookupableAttendees.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    cards
                }
                Divider()
            }
            .task(id: lookupableAttendees.joined(separator: "|")) {
                await loadProfiles()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.text.rectangle")
                    .font(.caption)
                    .foregroundStyle(Color.appAccentLight)
                Text("ATTENDEE PROFILES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.appAccentLight)
                    .tracking(0.6)
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if !profiles.isEmpty {
                    Text("\(profiles.count)/\(lookupableAttendees.count) found")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cards

    private var cards: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = loadError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.appRecording)
                    .padding(.horizontal, 14)
            }
            ForEach(lookupableAttendees, id: \.self) { email in
                if let profile = profiles[email.lowercased()] {
                    profileCard(profile: profile, fallbackEmail: email)
                } else if failed.contains(email.lowercased()) {
                    notFoundRow(email: email)
                } else if isLoading {
                    skeletonRow(email: email)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }

    private func profileCard(profile: ApolloService.Profile, fallbackEmail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Initials avatar — Apollo's photo URLs are often broken / behind
            // auth, so we don't try to load remote images and risk a flash of
            // broken state.
            InitialsAvatar(name: profile.name, size: 36, index: 0)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    if profile.recentlyJoined {
                        Text("Recently joined")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.appAccentLight)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.appAccent.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                if let title = profile.title, let org = profile.organizationName {
                    Text("\(title) · \(org)")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                } else if let title = profile.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                } else if let org = profile.organizationName {
                    Text(org)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }

                // Show one prior role when the current role is < 90 days old.
                if profile.recentlyJoined, profile.recentEmployment.count >= 2 {
                    let prior = profile.recentEmployment[1]
                    if let priorTitle = prior.title, let priorOrg = prior.organizationName {
                        Text("Previously: \(priorTitle) at \(priorOrg)")
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }

                HStack(spacing: 8) {
                    if let url = profile.linkedinURL {
                        Link(destination: url) {
                            Label("LinkedIn", systemImage: "link")
                                .font(.caption2.weight(.medium))
                        }
                    }
                    Text(fallbackEmail)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextMuted)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.appBorderStrong, lineWidth: 1)
        )
    }

    private func notFoundRow(email: String) -> some View {
        HStack(spacing: 10) {
            InitialsAvatar(name: email, size: 28, index: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(email)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                Text("No Apollo match")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func skeletonRow(email: String) -> some View {
        HStack(spacing: 10) {
            InitialsAvatar(name: email, size: 28, index: 0)
            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.appSurfaceSecondary)
                    .frame(width: 120, height: 10)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.appSurfaceSecondary)
                    .frame(width: 80, height: 8)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .redacted(reason: .placeholder)
    }

    // MARK: - Loading

    @MainActor
    private func loadProfiles() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        for email in lookupableAttendees {
            let key = email.lowercased()
            if profiles[key] != nil || failed.contains(key) { continue }
            do {
                if let profile = try await ApolloService.shared.lookupPerson(email: email) {
                    profiles[key] = profile
                } else {
                    failed.insert(key)
                }
            } catch {
                failed.insert(key)
                if loadError == nil {
                    // Surface the first error so the user knows something went
                    // wrong without showing one banner per attendee.
                    loadError = error.localizedDescription
                }
                Logger.general.warning("Apollo lookup failed for \(email, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
