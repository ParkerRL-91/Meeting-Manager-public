import SwiftUI
import os

/// Replaces — or sits alongside — the "CONTEXT" card on meeting views when
/// the user has Apollo integration enabled, an API key stored, and validated.
///
/// Surfaces a small profile card per non-local attendee: title, employer,
/// recent moves, LinkedIn link. Clicking a card row expands it to show
/// full employment history, industry, headcount, location, and a short
/// company description (when Apollo returns them).
///
/// When the Apollo integration is on AND the meeting has cached context
/// (related-meeting brief), the section header gets a small two-tab
/// segmented control: "Profiles" (this Apollo-backed UI) vs. "Brief"
/// (the existing RelatedMeetingsSection). The user picks. Selection is
/// persisted across views.
struct AttendeeProfileSection: View {
    let participants: [String]
    /// Lowercased email or name of the local user — excluded from lookups.
    let excludeIdentifiers: Set<String>
    /// Cached pre-meeting brief JSON. When present, the toggle to switch to
    /// "Brief" view appears in the header. nil → toggle is hidden and the
    /// section is profiles-only.
    var contextJSON: String? = nil
    /// Forwarded to the brief view when the user opens a related meeting.
    var onSelectMeeting: ((String) -> Void)? = nil

    @State private var profiles: [String: ApolloService.Profile] = [:]
    @State private var failed: Set<String> = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    /// Persisted section state — survives navigation between meetings.
    @AppStorage("attendeeProfileExpanded") private var isExpanded: Bool = true
    @AppStorage("attendeeProfileMode") private var modeRaw: String = Mode.profiles.rawValue

    /// Per-card expand state. Keyed by lowercased email.
    @State private var expandedCards: Set<String> = []

    private enum Mode: String {
        case profiles
        case brief
    }

    private var mode: Mode {
        Mode(rawValue: modeRaw) ?? .profiles
    }

    /// The mode actually rendered. Honors the user's persisted choice when both
    /// sources have content; otherwise falls back to whichever source is
    /// non-empty so the section never renders an empty body. (The persisted
    /// `mode` is global, so a meeting with a brief but no email-bearing
    /// attendees would otherwise show a "PRE-MEETING BRIEF" header over an
    /// empty body when the user last picked "Profiles" on another meeting.)
    private var effectiveMode: Mode {
        let canShowProfiles = !lookupableAttendees.isEmpty
        switch mode {
        case .brief:    return hasBrief ? .brief : (canShowProfiles ? .profiles : .brief)
        case .profiles: return canShowProfiles ? .profiles : (hasBrief ? .brief : .profiles)
        }
    }

    private var hasBrief: Bool {
        guard let contextJSON, !contextJSON.isEmpty else { return false }
        let ctx = RelevantMeetingService.parseCachedContext(from: contextJSON)
        return ctx.brief != nil || !ctx.relatedMeetings.isEmpty
    }

    private var lookupableAttendees: [String] {
        participants.filter { p in
            let lower = p.lowercased().trimmingCharacters(in: .whitespaces)
            guard !lower.isEmpty, lower.contains("@") else { return false }
            return !excludeIdentifiers.contains(lower)
        }
    }

    var body: some View {
        // Hide entirely when there's nothing to show in either mode.
        if lookupableAttendees.isEmpty && !hasBrief {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    switch effectiveMode {
                    case .brief:
                        // Reuse the existing brief layout. It manages its own
                        // expand/collapse for source meetings.
                        RelatedMeetingsSection(
                            contextJSON: contextJSON,
                            onSelectMeeting: onSelectMeeting
                        )
                        .padding(.top, 4)
                    case .profiles:
                        cards
                    }
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
        VStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.text.rectangle")
                        .font(.caption)
                        .foregroundStyle(Color.appAccentLight)
                    Text(headerTitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.appAccentLight)
                        .tracking(0.6)
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    if effectiveMode == .profiles, !profiles.isEmpty {
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

            // Two-mode toggle — only renders when both sources have something
            // to show. Otherwise just the single available source is implied.
            if isExpanded, hasBrief, !lookupableAttendees.isEmpty {
                modeSwitch
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
    }

    private var headerTitle: String {
        effectiveMode == .brief ? "PRE-MEETING BRIEF" : "ATTENDEE PROFILES"
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            modeButton(.profiles, label: "Profiles")
            modeButton(.brief, label: "Brief")
            Spacer()
        }
    }

    private func modeButton(_ target: Mode, label: String) -> some View {
        let isActive = mode == target
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                modeRaw = target.rawValue
            }
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(isActive ? Color.appTextPrimary : Color.appTextTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.appSurface : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? Color.appBorderStrong : Color.clear, lineWidth: 1)
                )
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
        let key = fallbackEmail.lowercased()
        let expanded = expandedCards.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if expanded { expandedCards.remove(key) }
                    else { expandedCards.insert(key) }
                }
            } label: {
                profileCardHeader(profile: profile, fallbackEmail: fallbackEmail, expanded: expanded)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                profileCardDetails(profile: profile)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.appBorderStrong, lineWidth: 1)
        )
    }

    private func profileCardHeader(profile: ApolloService.Profile, fallbackEmail: String, expanded: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.appTextTertiary)
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

                if !expanded, profile.recentlyJoined, profile.recentEmployment.count >= 2 {
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
        }
        .padding(10)
    }

    @ViewBuilder
    private func profileCardDetails(profile: ApolloService.Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if let headline = profile.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let location = profile.location {
                detailRow(icon: "mappin.and.ellipse", text: location)
            }

            // Career history. Skip the topmost row if it duplicates the
            // "Title · Company" already shown in the header.
            let history = Array(profile.recentEmployment.dropFirst())
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PREVIOUS ROLES")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.appTextTertiary)
                        .tracking(0.5)
                    ForEach(Array(history.enumerated()), id: \.offset) { _, row in
                        employmentRow(row)
                    }
                }
            }

            // Company information block
            if profile.industry != nil
                || profile.companyEmployees != nil
                || profile.companyDescription != nil
                || profile.companyWebsite != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("COMPANY")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.appTextTertiary)
                        .tracking(0.5)

                    if let industry = profile.industry, let size = profile.companyEmployees {
                        detailRow(icon: "building.2", text: "\(industry) · \(Self.formatHeadcount(size)) employees")
                    } else if let industry = profile.industry {
                        detailRow(icon: "building.2", text: industry)
                    } else if let size = profile.companyEmployees {
                        detailRow(icon: "person.3", text: "\(Self.formatHeadcount(size)) employees")
                    }

                    if let url = profile.companyWebsite {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Image(systemName: "globe")
                                    .font(.caption2)
                                Text(url.host ?? url.absoluteString)
                                    .font(.caption2.weight(.medium))
                            }
                        }
                    }

                    if let desc = profile.companyDescription {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    private func employmentRow(_ row: ApolloService.Employment) -> some View {
        let title = row.title ?? "Role"
        let org = row.organizationName ?? "—"
        let dateRange = Self.formatDateRange(start: row.startDate, end: row.endDate)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "briefcase")
                .font(.caption2)
                .foregroundStyle(Color.appTextTertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(title) — \(org)")
                    .font(.caption)
                    .foregroundStyle(Color.appTextPrimary)
                if !dateRange.isEmpty {
                    Text(dateRange)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(Color.appTextTertiary)
                .frame(width: 14)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        }
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

    // MARK: - Formatters

    private static func formatHeadcount(_ n: Int) -> String {
        if n >= 10_000 { return "\(n / 1000)k+" }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    private static func formatDateRange(start: Date?, end: Date?) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM yyyy"
        let startText = start.map { fmt.string(from: $0) }
        let endText = end.map { fmt.string(from: $0) } ?? (start != nil ? "Present" : nil)
        switch (startText, endText) {
        case let (s?, e?): return "\(s) – \(e)"
        case let (s?, nil): return s
        case let (nil, e?): return e
        default: return ""
        }
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
