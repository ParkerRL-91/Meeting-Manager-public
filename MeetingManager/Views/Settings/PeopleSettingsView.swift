import SwiftUI
import Contacts

/// Settings tab for the Person identity directory. Shows every known person,
/// their aliases, and their voice profile status. Supports searching, renaming
/// the canonical name, adding/removing aliases, and merging duplicate records.
///
/// This view is the Phase 3 management surface for the speaker-ID system.
/// Its primary job: let users confirm, correct, and clean up the automatic
/// identity groupings so voice profiles compound correctly over time.
struct PeopleSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var persons: [Person] = []
    @State private var voiceProfiles: [VoiceProfile] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var selectedPersonId: String?
    @State private var personToEdit: Person?
    @State private var mergeSource: Person?
    @State private var mergeTarget: Person?
    @State private var showMergeSheet = false

    // Contacts import state
    @State private var isImporting = false
    @State private var importResult: String?
    @State private var contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)

    private var filtered: [Person] {
        guard !searchText.isEmpty else { return persons }
        let q = searchText.lowercased()
        return persons.filter {
            $0.canonicalName.lowercased().contains(q) ||
            $0.aliases.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: List pane
            VStack(spacing: 0) {
                searchBar
                Divider()
                if isLoading {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                } else if filtered.isEmpty {
                    emptyState
                } else {
                    personList
                }
            }
            .frame(width: 260)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // MARK: Detail pane
            if let pid = selectedPersonId, let person = persons.first(where: { $0.id == pid }) {
                PersonDetailPane(
                    person: person,
                    voiceProfile: voiceProfiles.first(where: { $0.personId == pid }),
                    allPersons: persons,
                    onUpdated: { loadData() },
                    onMergeInto: { source, target in
                        mergeSource = source
                        mergeTarget = target
                        showMergeSheet = true
                    }
                )
            } else {
                VStack {
                    Spacer()
                    Text("Select a person to view details")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task { loadData() }
        .safeAreaInset(edge: .top) {
            ContactsImportBanner(
                authStatus: contactsAuthStatus,
                isImporting: isImporting,
                importResult: importResult,
                onImport: { runContactsImport() }
            )
        }
        .sheet(item: $mergeSource) { src in
            if let tgt = mergeTarget {
                MergeConfirmSheet(source: src, target: tgt, onConfirm: {
                    performMerge(source: src, target: tgt)
                }, onCancel: {
                    mergeSource = nil
                    mergeTarget = nil
                })
            }
        }
    }

    // MARK: - Sub-views

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search people…", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.2.slash")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No people yet" : "No match for \"\(searchText)\"")
                .font(.callout)
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Text("People are created automatically from meeting participants.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
        }
    }

    private var personList: some View {
        List(filtered, id: \.id, selection: $selectedPersonId) { person in
            PersonRow(
                person: person,
                hasVoiceProfile: voiceProfiles.contains(where: { $0.personId == person.id })
            )
            .listRowBackground(selectedPersonId == person.id
                ? Color.appAccent.opacity(0.12)
                : Color.clear)
        }
        .listStyle(.plain)
    }

    // MARK: - Data

    private func loadData() {
        isLoading = true
        Task {
            let pr = PersonRepository(database: AppDatabase.shared)
            let vr = VoiceProfileRepository(database: AppDatabase.shared)
            async let p = (try? await pr.allPersons()) ?? []
            async let v = (try? await vr.allProfiles()) ?? []
            let (loaded, profiles) = await (p, v)
            persons = loaded.sorted { $0.canonicalName < $1.canonicalName }
            voiceProfiles = profiles
            isLoading = false
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
            importResult = "Added \(created) · Updated \(updated)"
            isImporting = false
            loadData()
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            importResult = nil
        }
    }

    private func performMerge(source: Person, target: Person) {
        Task {
            let repo = PersonRepository(database: AppDatabase.shared)
            try? await repo.merge(sourceId: source.id, intoTargetId: target.id)
            if selectedPersonId == source.id { selectedPersonId = target.id }
            mergeSource = nil
            mergeTarget = nil
            loadData()
        }
    }
}

// MARK: - Person Row

private struct PersonRow: View {
    let person: Person
    let hasVoiceProfile: Bool

    var body: some View {
        HStack(spacing: 8) {
            InitialsAvatar(name: person.canonicalName, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.canonicalName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(person.aliases.count) alias\(person.aliases.count == 1 ? "" : "es")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasVoiceProfile {
                Image(systemName: "waveform.badge.mic")
                    .font(.caption)
                    .foregroundStyle(Color.appAccent)
                    .help("Has voice fingerprint")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail Pane

private struct PersonDetailPane: View {
    let person: Person
    let voiceProfile: VoiceProfile?
    let allPersons: [Person]
    let onUpdated: () -> Void
    let onMergeInto: (Person, Person) -> Void

    @State private var editingName = false
    @State private var draftName = ""
    @State private var newAlias = ""
    @State private var showMergeTarget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    InitialsAvatar(name: person.canonicalName, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        if editingName {
                            HStack {
                                TextField("Canonical name", text: $draftName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                    .onSubmit { saveRename() }
                                Button("Save") { saveRename() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                Button("Cancel") { editingName = false }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(person.canonicalName)
                                    .font(.title3.weight(.semibold))
                                Button {
                                    draftName = person.canonicalName
                                    editingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("Rename")
                            }
                        }
                        Text("Added \(person.createdAt.formatted(.dateTime.month().day().year()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)

                Divider()

                // Voice profile card
                VStack(alignment: .leading, spacing: 6) {
                    Label("Voice fingerprint", systemImage: "waveform.badge.mic")
                        .font(.subheadline.weight(.semibold))
                    if let vp = voiceProfile {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(vp.sampleCount) meeting sample\(vp.sampleCount == 1 ? "" : "s")")
                                    .font(.callout)
                                Text("Last updated \(vp.lastUpdatedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                deleteVoiceProfile()
                            } label: {
                                Label("Delete fingerprint", systemImage: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                        .padding(10)
                        .background(Color.appSurfaceSecondary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text("No fingerprint yet — will be built automatically after a meeting where this person's voice is confirmed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Aliases
                VStack(alignment: .leading, spacing: 8) {
                    Label("Known aliases", systemImage: "person.text.rectangle")
                        .font(.subheadline.weight(.semibold))
                    Text("All name/email formats that resolve to this person.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(person.aliases, id: \.self) { alias in
                        HStack {
                            Text(alias)
                                .font(.callout)
                                .foregroundStyle(alias == person.canonicalName ? .primary : .secondary)
                            if alias == person.canonicalName {
                                Text("canonical")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.appAccent.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            if alias != person.canonicalName {
                                Button {
                                    removeAlias(alias)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    HStack {
                        TextField("Add alias (name or email)", text: $newAlias)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addAlias() }
                        Button("Add") { addAlias() }
                            .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Divider()

                // Merge section
                VStack(alignment: .leading, spacing: 8) {
                    Label("Merge duplicate", systemImage: "arrow.triangle.merge")
                        .font(.subheadline.weight(.semibold))
                    Text("Merge this person into another record — all aliases and voice fingerprints will be combined.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let others = allPersons.filter { $0.id != person.id }
                    if !others.isEmpty {
                        Picker("Merge into…", selection: Binding<String?>(
                            get: { nil },
                            set: { targetId in
                                if let id = targetId,
                                   let target = allPersons.first(where: { $0.id == id }) {
                                    onMergeInto(person, target)
                                }
                            }
                        )) {
                            Text("Choose…").tag(String?.none)
                            ForEach(others) { p in
                                Text(p.canonicalName).tag(String?.some(p.id))
                            }
                        }
                        .frame(maxWidth: 300)
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Actions

    private func saveRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != person.canonicalName else {
            editingName = false
            return
        }
        Task {
            try? await AppDatabase.shared.writer.write { db in
                var updated = person
                updated.canonicalName = trimmed
                updated.updatedAt = Date()
                // Add the new canonical name as an alias so it can be matched
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

    private func deleteVoiceProfile() {
        Task {
            let repo = VoiceProfileRepository(database: AppDatabase.shared)
            if let pid = voiceProfile?.personId {
                try? await repo.delete(personId: pid)
            } else {
                try? await repo.delete(personName: person.canonicalName)
            }
            onUpdated()
        }
    }
}

// MARK: - Merge confirm sheet

private struct MergeConfirmSheet: View {
    let source: Person
    let target: Person
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge \"\(source.canonicalName)\" into \"\(target.canonicalName)\"?")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("This will:")
                    .font(.subheadline)
                Group {
                    Text("• Move all \(source.aliases.count) alias\(source.aliases.count == 1 ? "" : "es") to \(target.canonicalName)")
                    Text("• Transfer any voice fingerprint samples")
                    Text("• Delete the \"\(source.canonicalName)\" record permanently")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Merge", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Contacts import banner

private struct ContactsImportBanner: View {
    let authStatus: CNAuthorizationStatus
    let isImporting: Bool
    let importResult: String?
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Import from Contacts")
                    .font(.subheadline.weight(.medium))
                Text("Add names & emails to improve speaker identification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let result = importResult {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button {
                onImport()
            } label: {
                if isImporting {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Importing…")
                    }
                } else {
                    Text(authStatus == .authorized ? "Sync now" : "Allow access")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isImporting || authStatus == .denied || authStatus == .restricted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.appSurfaceSecondary.opacity(0.6))
        .overlay(Divider(), alignment: .bottom)
    }
}

