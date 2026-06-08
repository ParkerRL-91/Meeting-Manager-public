import SwiftUI

/// Apollo enrichment card for the People/Companies directory (PRJ-007
/// TASK-023). Built fresh — deliberately separate from
/// `AttendeeProfileSection` (the meeting-view card) so the directory's layout
/// can evolve without regressing the meeting card.
///
/// Renders in `.person` mode (a contact's title, employer, history, LinkedIn)
/// or `.company` mode (the organization's industry, headcount, website,
/// description, all read from the same Apollo person payload's org block).
/// The card owns no fetching — the parent loads via
/// `ApolloEnrichmentCoordinator` in a `.task(id:)` and passes the result in.
struct ApolloProfileCard: View {
    enum Mode { case person, company }

    let mode: Mode
    let profile: ApolloService.Profile?
    var isLoading: Bool = false
    /// Fallback label when the profile is still loading or empty — the
    /// person's name / email, or the company's display name.
    var fallbackName: String
    /// Explicit re-fetch. Hidden when nil.
    var onRefresh: (() -> Void)? = nil

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded, profile != nil {
                details
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.appBorderStrong, lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Header

    private var sectionLabel: String {
        mode == .company ? "COMPANY PROFILE" : "PROFILE"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(sectionLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.appAccentLight)
                        .tracking(0.6)
                    if isLoading { ProgressView().controlSize(.mini) }
                    Spacer()
                    if let onRefresh {
                        Button(action: onRefresh) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.appTextTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh from Apollo")
                    }
                }

                if let profile {
                    primaryLine(profile)
                } else if isLoading {
                    Text("Looking up \(fallbackName)…")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                } else {
                    Text("No Apollo match")
                        .font(.caption)
                        .foregroundStyle(Color.appTextMuted)
                }
            }

            if profile != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.appTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        switch mode {
        case .person:
            InitialsAvatar(name: profile?.name ?? fallbackName, size: 40, index: 0)
        case .company:
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.appAccent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "building.2.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.appAccent)
            }
        }
    }

    @ViewBuilder
    private func primaryLine(_ profile: ApolloService.Profile) -> some View {
        switch mode {
        case .person:
            Text(profile.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)
            if let title = profile.title, let org = profile.organizationName {
                Text("\(title) \u{00B7} \(org)")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            } else if let title = profile.title {
                Text(title).font(.caption).foregroundStyle(Color.appTextSecondary)
            } else if let org = profile.organizationName {
                Text(org).font(.caption).foregroundStyle(Color.appTextSecondary)
            }
            if let url = profile.linkedinURL {
                Link(destination: url) {
                    Label("LinkedIn", systemImage: "link")
                        .font(.caption2.weight(.medium))
                }
            }
        case .company:
            Text(profile.organizationName ?? fallbackName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)
            if let industry = profile.industry, let size = profile.companyEmployees {
                Text("\(industry) \u{00B7} \(Self.formatHeadcount(size)) employees")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            } else if let industry = profile.industry {
                Text(industry).font(.caption).foregroundStyle(Color.appTextSecondary)
            } else if let size = profile.companyEmployees {
                Text("\(Self.formatHeadcount(size)) employees")
                    .font(.caption).foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var details: some View {
        if let profile {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                switch mode {
                case .person:   personDetails(profile)
                case .company:  companyDetails(profile)
                }
            }
        }
    }

    @ViewBuilder
    private func personDetails(_ profile: ApolloService.Profile) -> some View {
        if let headline = profile.headline {
            Text(headline)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let location = profile.location {
            detailRow(icon: "mappin.and.ellipse", text: location)
        }
        let history = Array(profile.recentEmployment.dropFirst())
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                detailHeader("PREVIOUS ROLES")
                ForEach(Array(history.enumerated()), id: \.offset) { _, row in
                    employmentRow(row)
                }
            }
        }
        // The company block is useful on the person card too.
        companyBlock(profile)
    }

    @ViewBuilder
    private func companyDetails(_ profile: ApolloService.Profile) -> some View {
        if let location = profile.location {
            detailRow(icon: "mappin.and.ellipse", text: location)
        }
        companyBlock(profile)
    }

    @ViewBuilder
    private func companyBlock(_ profile: ApolloService.Profile) -> some View {
        if profile.industry != nil
            || profile.companyEmployees != nil
            || profile.companyDescription != nil
            || profile.companyWebsite != nil {
            VStack(alignment: .leading, spacing: 4) {
                detailHeader("COMPANY")
                if let industry = profile.industry, let size = profile.companyEmployees {
                    detailRow(icon: "building.2", text: "\(industry) \u{00B7} \(Self.formatHeadcount(size)) employees")
                } else if let industry = profile.industry {
                    detailRow(icon: "building.2", text: industry)
                } else if let size = profile.companyEmployees {
                    detailRow(icon: "person.3", text: "\(Self.formatHeadcount(size)) employees")
                }
                if let url = profile.companyWebsite {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe").font(.caption2)
                            Text(url.host ?? url.absoluteString).font(.caption2.weight(.medium))
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

    // MARK: - Row helpers

    private func detailHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.appTextTertiary)
            .tracking(0.5)
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

    private func employmentRow(_ row: ApolloService.Employment) -> some View {
        let title = row.title ?? "Role"
        let org = row.organizationName ?? "\u{2014}"
        let dateRange = Self.formatDateRange(start: row.startDate, end: row.endDate)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "briefcase")
                .font(.caption2)
                .foregroundStyle(Color.appTextTertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(title) \u{2014} \(org)")
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
        case let (s?, e?): return "\(s) \u{2013} \(e)"
        case let (s?, nil): return s
        case let (nil, e?): return e
        default: return ""
        }
    }
}
