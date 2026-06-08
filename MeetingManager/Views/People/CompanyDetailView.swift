import SwiftUI

/// Detail pane for a derived `Company`: members, every meeting with anyone
/// from the org, and cross-meeting rollups (open action items + recent
/// summaries). Companies are runtime-derived (ADR-014); this view holds no
/// company-specific persisted state.
struct CompanyDetailView: View {
    let company: Company
    let voiceProfiles: [VoiceProfile]
    /// Switch the directory back to People and select this member.
    let onSelectPerson: (Person) -> Void

    @Environment(AppState.self) private var appState

    @State private var openItems: [(meeting: Meeting, items: [ActionItem])] = []
    @State private var recentSummaries: [(meeting: Meeting, summary: MeetingSummary)] = []
    @State private var apolloProfile: ApolloService.Profile?
    @State private var apolloLoading = false

    private let rollups = MeetingRollupService()

    /// Apollo card renders only with the integration on, a validated key, a
    /// real (non-consumer) domain, and at least one member email to look up.
    private var apolloEnabled: Bool {
        appState.settings.apolloProfilePrepEnabled && appState.settings.apolloKeyValidated
    }

    /// First member email that shares the company's domain — drives the
    /// company-level Apollo lookup.
    private var representativeEmail: String? {
        company.people.lazy.compactMap(\.primaryEmail).first {
            $0.components(separatedBy: "@").last?.lowercased() == company.domain
        }
    }

    private var showApolloCard: Bool {
        apolloEnabled && !company.isPersonalBucket && representativeEmail != nil
    }

    private var companyMeetings: [Meeting] {
        CompanyGroupingService.meetingsInvolving(people: company.people, in: appState.meetings)
            .sorted { $0.effectiveDate > $1.effectiveDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if showApolloCard {
                    ApolloProfileCard(
                        mode: .company,
                        profile: apolloProfile,
                        isLoading: apolloLoading,
                        fallbackName: company.displayName,
                        onRefresh: { Task { await loadApollo(force: true) } }
                    )
                    .padding(.bottom, 8)
                }
                Divider().background(Color.appSeparator).padding(.horizontal, 24)
                peopleSection
                Divider().background(Color.appSeparator).padding(.horizontal, 24)
                meetingsSection
                if !openItems.isEmpty { rollupActionItems }
                if !recentSummaries.isEmpty { rollupSummaries }
            }
        }
        .background(Color.appBackground)
        .task(id: company.id) {
            await loadRollups()
            await loadApollo(force: false)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.appAccent.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: company.isPersonalBucket ? "person.crop.circle" : "building.2.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(spacing: 6) {
                Text(company.displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                if !company.domain.isEmpty {
                    Text(company.domain)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                }
                HStack(spacing: 12) {
                    Label("\(company.people.count) \(company.people.count == 1 ? "person" : "people")", systemImage: "person.2")
                        .font(.subheadline).foregroundStyle(Color.appTextSecondary)
                    Label("\(company.meetingCount) meeting\(company.meetingCount == 1 ? "" : "s")", systemImage: "calendar")
                        .font(.subheadline).foregroundStyle(Color.appTextSecondary)
                    if let date = company.lastMet {
                        Label(relativeDate(date), systemImage: "clock")
                            .font(.subheadline).foregroundStyle(Color.appTextSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - People

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("People")
            ForEach(company.people) { person in
                let meetings = CompanyGroupingService.meetingsInvolving(people: [person], in: appState.meetings)
                PersonListRow(
                    person: person,
                    meetingCount: meetings.count,
                    lastMeeting: meetings.map(\.effectiveDate).max(),
                    hasVoiceProfile: voiceProfiles.contains { $0.personId == person.id },
                    isSelected: false
                )
                .onTapGesture { onSelectPerson(person) }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Meetings

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Meetings")
            if companyMeetings.isEmpty {
                Text("No meetings recorded yet")
                    .font(.callout).foregroundStyle(Color.appTextSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(companyMeetings) { meeting in
                    PersonMeetingRow(meeting: meeting)
                        .onTapGesture {
                            appState.selectedMeetingId = meeting.id
                            appState.sidebarDestination = .meetings
                        }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Rollups

    private var rollupActionItems: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Open Action Items")
            ForEach(openItems, id: \.meeting.id) { entry in
                ForEach(entry.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle").font(.caption2).foregroundStyle(Color.appTextTertiary).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.callout).foregroundStyle(Color.appTextPrimary)
                            Text(entry.meeting.title).font(.caption).foregroundStyle(Color.appTextTertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
    }

    private var rollupSummaries: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent Summaries")
            ForEach(recentSummaries, id: \.meeting.id) { entry in
                Button {
                    appState.selectedMeetingId = entry.meeting.id
                    appState.sidebarDestination = .meetings
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.meeting.title).font(.subheadline.weight(.medium)).foregroundStyle(Color.appTextPrimary)
                        Text(snippet(entry.summary.summaryText)).font(.caption).foregroundStyle(Color.appTextSecondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 32)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.appTextTertiary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private func loadRollups() async {
        let meetings = companyMeetings
        openItems = await rollups.openActionItems(forMeetings: meetings)
        recentSummaries = await rollups.recentSummaries(forMeetings: meetings)
    }

    private func loadApollo(force: Bool) async {
        guard showApolloCard, let email = representativeEmail else { return }
        apolloLoading = true
        defer { apolloLoading = false }
        let coordinator = ApolloEnrichmentCoordinator.shared
        if force {
            apolloProfile = await coordinator.refreshCompany(
                domain: company.domain, representativeEmail: email, gateEnabled: apolloEnabled
            )
        } else {
            apolloProfile = await coordinator.companyProfile(
                domain: company.domain, representativeEmail: email, gateEnabled: apolloEnabled
            )
        }
    }

    private func snippet(_ text: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? text
        let trimmed = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return String(trimmed.prefix(160))
    }

    private func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
