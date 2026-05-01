import SwiftUI
import Contacts

/// Main People directory — lists every known Person, shows their meeting
/// history in the detail pane, and surfaces inline identity management
/// (aliases, voice fingerprint, merge, Contacts import) via an expandable
/// "Manage Identity" section. No separate Settings tab required.
struct PeopleView: View {
    @Environment(AppState.self) private var appState

    @State private var persons: [Person] = []
    @State private var voiceProfiles: [VoiceProfile] = []
    @State private var searchQuery = ""
    @State private var selectedPersonId: String?
    @State private var isLoadingPersons = false

    // Contacts import
    @State private var isImporting = false
    @State private var importResult: String?
    @State private var contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)

    private var filteredPersons: [Person] {
        guard !searchQuery.isEmpty else { return persons }
        let q = searchQuery.lowercased()
        return persons.filter {
            $0.canonicalName.lowercased().contains(q) ||
            $0.aliases.contains { $0.lowercased().contains(q) }
        }
    }

    private var meetings: [Meeting] { appState.meetings }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left: People list
            VStack(spacing: 0) {
                listHeader
                Divider().background(Color.appSeparator)

                if isLoadingPersons {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                } else if filteredPersons.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredPersons) { person in
                                PersonListRow(
                                    person: person,
                                    meetingCount: meetingCount(for: person),
                                    lastMeeting: lastMeetingDate(for: person),
                                    hasVoiceProfile: voiceProfiles.contains { $0.personId == person.id },
                                    isSelected: selectedPersonId == person.id
                                )
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedPersonId = person.id
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(width: 280)
            .background(Color.appBackground)

            Divider().background(Color.appSeparator)

            // MARK: - Right: Detail
            if let pid = selectedPersonId,
               let person = persons.first(where: { $0.id == pid }) {
                PersonDetailView(
                    person: person,
                    meetings: meetingsFor(person: person),
                    voiceProfile: voiceProfiles.first(where: { $0.personId == pid }),
                    allPersons: persons,
                    onUpdated: { loadData() }
                )
                .id(pid)
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.appTextTertiary)
                    Text("Select a person")
                        .font(.title3)
                        .foregroundStyle(Color.appTextSecondary)
                    Text("View meeting history and manage their identity")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
            }
        }
        .background(Color.appBackground)
        .task { loadData() }
    }

    // MARK: - Header with search + import

    private var listHeader: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("People")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    Text("\(filteredPersons.count) contacts")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
                Spacer()
                Button {
                    runContactsImport()
                } label: {
                    if isImporting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.appAccent)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isImporting)
                .help(contactsAuthStatus == .authorized ? "Sync from Contacts" : "Import from Contacts")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, importResult != nil ? 6 : 10)

            if let result = importResult {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextTertiary)
                TextField("Search people…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2.slash")
                .font(.title)
                .foregroundStyle(Color.appTextTertiary)
            Text(searchQuery.isEmpty ? "No people yet" : "No match for \"\(searchQuery)\"")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
            if searchQuery.isEmpty {
                Text("People are built automatically from meeting participants.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            Spacer()
        }
    }

    // MARK: - Data helpers

    private func meetingsFor(person: Person) -> [Meeting] {
        meetings
            .filter { m in m.participantList.contains { person.matches(participant: $0) } }
            .sorted { $0.effectiveDate > $1.effectiveDate }
    }

    private func meetingCount(for person: Person) -> Int {
        meetings.filter { m in m.participantList.contains { person.matches(participant: $0) } }.count
    }

    private func lastMeetingDate(for person: Person) -> Date? {
        meetingsFor(person: person).first?.effectiveDate
    }

    private func loadData() {
        isLoadingPersons = true
        Task {
            let pr = PersonRepository(database: AppDatabase.shared)
            let vr = VoiceProfileRepository(database: AppDatabase.shared)
            async let p = (try? await pr.allPersons()) ?? []
            async let v = (try? await vr.allProfiles()) ?? []
            let (loaded, profiles) = await (p, v)
            persons = loaded.sorted { $0.canonicalName < $1.canonicalName }
            voiceProfiles = profiles
            isLoadingPersons = false
            if selectedPersonId == nil, let first = loaded.first {
                selectedPersonId = first.id
            }
        }
    }

    private func runContactsImport() {
        Task {
            if contactsAuthStatus != .authorized {
                let granted = await ContactsImportService.shared.requestAccess()
                contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)
                guard granted else { return }
            }
            isImporting = true
            importResult = nil
            let repo = PersonRepository(database: AppDatabase.shared)
            let (created, updated) = await ContactsImportService.shared.importContacts(into: repo)
            importResult = "Added \(created) \u{00B7} Updated \(updated)"
            isImporting = false
            loadData()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            importResult = nil
        }
    }
}

// MARK: - Person list row

private struct PersonListRow: View {
    let person: Person
    let meetingCount: Int
    let lastMeeting: Date?
    let hasVoiceProfile: Bool
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            InitialsAvatar(name: person.canonicalName, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(person.canonicalName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(1)
                    if let org = person.orgHint {
                        Text(org)
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent.opacity(0.8))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.appAccent.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text("\(meetingCount) meeting\(meetingCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                    if let date = lastMeeting {
                        Text("\u{00B7}").font(.caption).foregroundStyle(Color.appTextTertiary)
                        Text(relativeDateShort(date)).font(.caption).foregroundStyle(Color.appTextSecondary)
                    }
                }
            }

            Spacer()

            if hasVoiceProfile {
                Image(systemName: "waveform.badge.mic")
                    .font(.caption)
                    .foregroundStyle(Color.appAccent.opacity(0.7))
                    .help("Voice fingerprint stored")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.appAccent.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func relativeDateShort(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Person detail view

private struct PersonDetailView: View {
    let person: Person
    let meetings: [Meeting]
    let voiceProfile: VoiceProfile?
    let allPersons: [Person]
    let onUpdated: () -> Void

    @Environment(AppState.self) private var appState
    @State private var showManage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Profile header
                VStack(spacing: 14) {
                    InitialsAvatar(name: person.canonicalName, size: 72)

                    VStack(spacing: 6) {
                        Text(person.canonicalName)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)

                        if let org = person.orgHint, let domain = person.domain {
                            HStack(spacing: 4) {
                                Image(systemName: "building.2").font(.caption)
                                Text("\(org) \u{00B7} \(domain)").font(.subheadline)
                            }
                            .foregroundStyle(Color.appTextSecondary)
                        }

                        HStack(spacing: 12) {
                            Label("\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")", systemImage: "calendar")
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)

                            if let date = meetings.first?.effectiveDate {
                                Label(relativeDate(date), systemImage: "clock")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.appTextSecondary)
                            }

                            if voiceProfile != nil {
                                Label("Voice ID", systemImage: "waveform.badge.mic")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.appAccent)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)

                Divider().background(Color.appSeparator).padding(.horizontal, 24)

                // Expandable identity management
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showManage.toggle() }
                    } label: {
                        HStack {
                            Label("Manage Identity", systemImage: "person.badge.key.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.appTextTertiary)
                                .textCase(.uppercase)
                                .tracking(0.6)
                            Spacer()
                            Image(systemName: showManage ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appTextTertiary)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .padding(.bottom, showManage ? 10 : 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showManage {
                        IdentityManagementSection(
                            person: person,
                            voiceProfile: voiceProfile,
                            allPersons: allPersons,
                            onUpdated: onUpdated
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                Divider().background(Color.appSeparator).padding(.horizontal, 24)

                // Meeting history
                if meetings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.title2).foregroundStyle(Color.appTextTertiary)
                        Text("No meetings recorded yet")
                            .font(.callout).foregroundStyle(Color.appTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Meeting History")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.appTextTertiary)
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .padding(.top, 20)
                        ForEach(meetings) { meeting in
                            PersonMeetingRow(meeting: meeting, personName: person.canonicalName)
                                .onTapGesture {
                                    appState.selectedMeetingId = meeting.id
                                    appState.sidebarDestination = .meetings
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
        }
        .background(Color.appBackground)
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

// MARK: - Identity management (expandable section)

private struct IdentityManagementSection: View {
    let person: Person
    let voiceProfile: VoiceProfile?
    let allPersons: [Person]
    let onUpdated: () -> Void

    @State private var editingName = false
    @State private var draftName = ""
    @State private var newAlias = ""
    @State private var mergeTargetId: String? = nil
    @State private var showMergeConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Display name
            VStack(alignment: .leading, spacing: 6) {
                Text("Display name")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if editingName {
                    HStack(spacing: 6) {
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveName() }
                        Button("Save") { saveName() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel") { editingName = false }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(person.canonicalName).font(.callout)
                        Button {
                            draftName = person.canonicalName
                            editingName = true
                        } label: {
                            Image(systemName: "pencil").font(.caption).foregroundStyle(Color.appAccent)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            // Aliases
            VStack(alignment: .leading, spacing: 6) {
                Text("Known aliases")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                let nonCanonical = person.aliases.filter { $0 != person.canonicalName }
                if nonCanonical.isEmpty {
                    Text("No additional aliases yet.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(nonCanonical, id: \.self) { alias in
                    HStack {
                        Image(systemName: alias.contains("@") ? "envelope" : "person")
                            .font(.caption).foregroundStyle(.tertiary).frame(width: 14)
                        Text(alias).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            removeAlias(alias)
                        } label: {
                            Image(systemName: "minus.circle").foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 6) {
                    TextField("Add alias or email\u{2026}", text: $newAlias)
                        .textFieldStyle(.roundedBorder).font(.callout)
                        .onSubmit { addAlias() }
                    Button("Add") { addAlias() }
                        .controlSize(.small)
                        .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            // Voice fingerprint
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice fingerprint")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let vp = voiceProfile {
                    HStack {
                        Image(systemName: "waveform.badge.mic").foregroundStyle(Color.appAccent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(vp.sampleCount) sample\(vp.sampleCount == 1 ? "" : "s")").font(.callout)
                            Text("Updated \(vp.lastUpdatedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { deleteVoiceProfile(vp) }
                            .buttonStyle(.borderless).font(.caption).foregroundStyle(.red)
                    }
                    .padding(8)
                    .background(Color.appSurfaceSecondary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Text("None yet \u{2014} built automatically when this person\u{2019}s voice is confirmed in a transcript.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Merge
            let others = allPersons.filter { $0.id != person.id }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Merge duplicate")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Picker("Merge into\u{2026}", selection: $mergeTargetId) {
                            Text("Choose person\u{2026}").tag(String?.none)
                            ForEach(others) { p in
                                Text(p.canonicalName).tag(String?.some(p.id))
                            }
                        }
                        .frame(maxWidth: 220)
                        Button("Merge") { showMergeConfirm = true }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(mergeTargetId == nil).tint(.red)
                    }
                }
            }
        }
        .confirmationDialog(
            mergeConfirmTitle,
            isPresented: $showMergeConfirm,
            titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) { performMerge() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All aliases and voice fingerprints will be combined. \"\(person.canonicalName)\" will be deleted.")
        }
    }

    private var mergeConfirmTitle: String {
        if let tid = mergeTargetId,
           let target = allPersons.first(where: { $0.id == tid }) {
            return "Merge into \"\(target.canonicalName)\"?"
        }
        return "Merge person?"
    }

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != person.canonicalName else { editingName = false; return }
        Task {
            try? await AppDatabase.shared.writer.write { db in
                var updated = person
                updated.canonicalName = trimmed
                updated.updatedAt = Date()
                var aliases = updated.aliases
                if !aliases.contains(trimmed) { aliases.append(trimmed) }
                updated.setAliases(aliases)
                try updated.update(db)
            }
            editingName = false
            onUpdated()
        }
    }

    private func removeAlias(_ alias: String) {
        Task {
            try? await AppDatabase.shared.writer.write { db in
                var updated = person
                updated.setAliases(updated.aliases.filter { $0 != alias })
                updated.updatedAt = Date()
                try updated.update(db)
            }
            onUpdated()
        }
    }

    private func addAlias() {
        let trimmed = newAlias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        newAlias = ""
        Task {
            let repo = PersonRepository(database: AppDatabase.shared)
            try? await repo.addAlias(trimmed, toPersonId: person.id)
            onUpdated()
        }
    }

    private func deleteVoiceProfile(_ vp: VoiceProfile) {
        Task {
            let repo = VoiceProfileRepository(database: AppDatabase.shared)
            if let pid = vp.personId {
                try? await repo.delete(personId: pid)
            } else {
                try? await repo.delete(personName: vp.personName)
            }
            onUpdated()
        }
    }

    private func performMerge() {
        guard let targetId = mergeTargetId else { return }
        Task {
            let repo = PersonRepository(database: AppDatabase.shared)
            try? await repo.merge(sourceId: person.id, intoTargetId: targetId)
            mergeTargetId = nil
            onUpdated()
        }
    }
}

// MARK: - Meeting row

private struct PersonMeetingRow: View {
    let meeting: Meeting
    var personName: String = ""

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(meeting.effectiveDate.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appTextSecondary).textCase(.uppercase)
                Text(meeting.effectiveDate.formatted(.dateTime.day()))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appTextPrimary)
            }
            .frame(width: 36).padding(.vertical, 6)
            .background(Color.appSurface).clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.subheadline.weight(.medium)).foregroundStyle(Color.appTextPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meeting.effectiveDate.formatted(.dateTime.hour().minute()))
                        .font(.caption).foregroundStyle(Color.appTextSecondary)
                    let dur = meeting.formattedDuration
                    if dur != "--" {
                        Text("\u{00B7}").font(.caption).foregroundStyle(Color.appTextTertiary)
                        Text(dur).font(.caption).foregroundStyle(Color.appTextSecondary)
                    }
                    let others = meeting.participantList.filter { $0 != personName }
                    if !others.isEmpty {
                        Text("\u{00B7}").font(.caption).foregroundStyle(Color.appTextTertiary)
                        Text("+\(others.count) others").font(.caption).foregroundStyle(Color.appTextSecondary)
                    }
                }
            }

            Spacer()

            Image(systemName: meeting.status == .complete ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(meeting.status == .complete ? Color.appSuccess : Color.appTextTertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
