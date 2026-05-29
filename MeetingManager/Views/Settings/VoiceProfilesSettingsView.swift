import SwiftUI

/// Settings tab for managing the cross-meeting voice fingerprint database.
/// Lists every learned profile with its sample count, lets the user delete
/// individual profiles, and exposes a one-shot "Rebuild from history" button
/// that walks every meeting in the DB and re-extracts embeddings from
/// confirmed speaker turns.
struct VoiceProfilesSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var profiles: [VoiceProfile] = []
    @State private var isLoading: Bool = false
    @State private var isRebuilding: Bool = false
    @State private var rebuildResult: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Voice profiles let Meeting Manager recognise speakers across meetings without an AI call. Profiles are built automatically when you confirm a speaker name in a transcript — manual renames are the highest-confidence signal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Profiles (\(profiles.count))") {
                if isLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                } else if profiles.isEmpty {
                    Text("No voice profiles yet. They'll appear here as you confirm speaker names in transcripts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        ProfileRow(profile: profile, onDelete: { delete(profile) })
                    }
                }
            }

            Section("Rebuild") {
                HStack {
                    Button {
                        rebuildFromHistory()
                    } label: {
                        if isRebuilding {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Rebuilding…")
                            }
                        } else {
                            Label("Rebuild from history", systemImage: "arrow.clockwise.circle")
                        }
                    }
                    .disabled(isRebuilding)

                    if let result = rebuildResult {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Text("Walks every recorded meeting that has confirmed speaker names and re-extracts voice fingerprints from each speaker's audio. Use this once after upgrading to bootstrap profiles from your existing meeting history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let repo = VoiceProfileRepository(database: AppDatabase.shared)
        profiles = ((try? await repo.allProfiles()) ?? [])
            .sorted { ($0.sampleCount, $0.personName) > ($1.sampleCount, $1.personName) }
    }

    /// Reset a person's voice memory entirely: remove the EMA centroid AND the
    /// per-utterance samples it was built from. Clearing both is what makes this
    /// a real recovery path for a poisoned profile — deleting only the profile
    /// row used to leave orphaned samples behind that a later rebuild would
    /// resurrect. The voice is re-learned cleanly from future meetings.
    private func delete(_ profile: VoiceProfile) {
        Task {
            let profileRepo = VoiceProfileRepository(database: AppDatabase.shared)
            try? await profileRepo.delete(personName: profile.personName)
            if let pid = profile.personId {
                let sampleRepo = VoiceSampleRepository(database: AppDatabase.shared)
                try? await sampleRepo.deleteSamples(forPersonId: pid)
            }
            await load()
        }
    }

    private func rebuildFromHistory() {
        isRebuilding = true
        rebuildResult = nil
        errorMessage = nil
        Task {
            let count = await appState.rebuildVoiceProfilesFromHistory()
            rebuildResult = "Processed \(count) meeting\(count == 1 ? "" : "s")"
            await load()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            rebuildResult = nil
            isRebuilding = false
        }
    }
}

private struct ProfileRow: View {
    let profile: VoiceProfile
    let onDelete: () -> Void

    var body: some View {
        HStack {
            InitialsAvatar(name: profile.personName, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.personName)
                    .font(.subheadline.weight(.medium))
                Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s") · last updated \(relativeDate(profile.lastUpdatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
