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
    @State private var healthSignals: [RelationshipHealth.Signal] = []
    @State private var faqFacts: [EntityFact] = []
    @State private var faqExported = false
    @State private var showPractice = false

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
                if !healthSignals.isEmpty {
                    RelationshipSignalChips(signals: healthSignals)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                }
                peopleSection
                Divider().background(Color.appSeparator).padding(.horizontal, 24)
                meetingsSection
                if !faqFacts.isEmpty { faqSection }
                if !openItems.isEmpty { rollupActionItems }
                if !recentSummaries.isEmpty { rollupSummaries }
            }
        }
        .background(Color.appBackground)
        .task(id: company.id) {
            await loadRollups()
            await loadApollo(force: false)
        }
        .sheet(isPresented: $showPractice) {
            PracticeModeView(
                personaName: company.displayName,
                entityType: "company",
                entityKey: company.domain
            )
            .environment(appState)
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

    // MARK: - FAQ & Objections (TASK-063)

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("FAQ & Objections")
                Spacer()
                Button {
                    showPractice = true
                } label: {
                    Label("Practice", systemImage: "theatermasks")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
                .help("Rehearse against this account's recorded objections and questions")
                Button {
                    Task { await exportFAQDoc() }
                } label: {
                    Label(faqExported ? "Exported" : "Export as doc",
                          systemImage: faqExported ? "checkmark" : "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
                .disabled(KnowledgeBaseService.shared.rootURL == nil)
                .help(KnowledgeBaseService.shared.rootURL == nil
                      ? "Configure a Knowledge Base folder in Settings to export"
                      : "Write this log to your Knowledge Base folder")
            }
            ForEach(faqFacts) { fact in
                Button {
                    appState.selectedMeetingId = fact.meetingId
                    appState.sidebarDestination = .meetings
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(fact.kind == "objection" ? "Objection" : "Question")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(fact.kind == "objection" ? Color.orange : Color.appAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((fact.kind == "objection" ? Color.orange : Color.appAccent).opacity(0.13))
                            .clipShape(Capsule())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.text)
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                            Text(faqMeetingLine(fact))
                                .font(.caption2)
                                .foregroundStyle(Color.appTextTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
    }

    private func faqMeetingLine(_ fact: EntityFact) -> String {
        guard let meeting = companyMeetings.first(where: { $0.id == fact.meetingId }) else {
            return fact.extractedAt.formatted(date: .abbreviated, time: .omitted)
        }
        let who = fact.owner.map { "\($0) — " } ?? ""
        return "\(who)\(meeting.title) · \(meeting.effectiveDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private func exportFAQDoc() async {
        guard let root = KnowledgeBaseService.shared.rootURL else { return }
        let dir = root.appendingPathComponent("Accounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(company.displayName) — FAQ.md")

        let df = DateFormatter()
        df.dateStyle = .medium
        var lines = ["# \(company.displayName) — FAQ & Objections", "",
                     "Generated \(df.string(from: Date())) from meeting records.", ""]
        let questions = faqFacts.filter { $0.kind == "question" }
        let objections = faqFacts.filter { $0.kind == "objection" }
        if !questions.isEmpty {
            lines.append("## Questions raised")
            lines.append(contentsOf: questions.map { "- \($0.text) _(\(faqMeetingLine($0)))_" })
            lines.append("")
        }
        if !objections.isEmpty {
            lines.append("## Objections raised")
            lines.append(contentsOf: objections.map { "- \($0.text) _(\(faqMeetingLine($0)))_" })
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        await KnowledgeBaseService.shared.reindexFile(url: url)
        faqExported = true
        try? await Task.sleep(for: .seconds(2))
        faqExported = false
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
        healthSignals = RelationshipHealth.signals(
            meetingDates: meetings.map(\.effectiveDate),
            openItems: openItems.flatMap(\.items).map { ($0.extractedAt, $0.dueDate) })
        faqFacts = ((try? await EntityFactRepository(database: AppDatabase.shared)
            .facts(entityType: "company", entityKey: company.domain, limit: 60)) ?? [])
            .filter { $0.kind == "question" || $0.kind == "objection" }
            .prefix(20).map { $0 }
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
