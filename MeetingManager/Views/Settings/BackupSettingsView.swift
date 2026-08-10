import SwiftUI
import AppKit

/// Backup & Restore settings (PRJ-017 F5). Pick a destination folder, choose
/// what to include, back up on demand (plus automatic weekly), and restore from
/// a backup on this or a fresh machine.
struct BackupSettingsView: View {
    @Environment(AppState.self) private var appState
    private let backup = BackupService.shared

    @State private var audioUsageBytes: Int64 = 0
    @State private var restoreCandidate: URL?
    @State private var restoreManifest: BackupManifest?
    @State private var restoreError: String?
    @State private var showRestartPrompt = false

    var body: some View {
        Form {
            destinationSection
            scopeSection
            backupNowSection
            restoreSection
        }
        .formStyle(.grouped)
        .task {
            audioUsageBytes = await Task.detached { AudioRetention.currentAudioUsageBytes() }.value
        }
        .alert("Restore from this backup?", isPresented: Binding(
            get: { restoreManifest != nil },
            set: { if !$0 { restoreManifest = nil; restoreCandidate = nil } }
        ), presenting: restoreManifest) { _ in
            Button("Cancel", role: .cancel) { restoreManifest = nil; restoreCandidate = nil }
            Button("Restart & Restore", role: .destructive) { stageAndPromptRestart() }
        } message: { manifest in
            Text("This backup holds \(manifest.meetingCount) meetings, \(manifest.transcriptCount) transcript segments, and \(manifest.decisionCount) decisions (from v\(manifest.appVersion)). Your current data will be moved aside and replaced when the app restarts.")
        }
        .alert("Restore staged", isPresented: $showRestartPrompt) {
            Button("Relaunch Now") { relaunch() }
            Button("Later", role: .cancel) { }
        } message: {
            Text("The backup will be applied the next time Meeting Manager launches. After restoring, you'll need to re-enter your API keys and re-connect Google Calendar (those aren't included in a backup).")
        }
        .alert("Couldn't Restore", isPresented: Binding(
            get: { restoreError != nil }, set: { if !$0 { restoreError = nil } }
        )) {
            Button("OK", role: .cancel) { restoreError = nil }
        } message: { Text(restoreError ?? "") }
    }

    // MARK: - Destination

    private var destinationPath: String { appState.settings.backupDestinationPath }
    private var hasDestination: Bool { !destinationPath.isEmpty }

    private var destinationSection: some View {
        Section("Backup location") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hasDestination ? destinationPath : "No folder chosen")
                        .font(.callout)
                        .foregroundStyle(hasDestination ? Color.appTextPrimary : Color.appTextTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("A “MeetingManagerBackup” folder is created inside this location.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
                Spacer()
                Button("Choose…") { chooseDestination() }
            }
        }
    }

    // MARK: - Scope

    private var scopeSection: some View {
        @Bindable var appState = appState
        return Section("What to include") {
            LabeledContent("Transcripts, summaries, tasks, people, settings") {
                Text("Always included").font(.caption).foregroundStyle(Color.appTextTertiary)
            }
            Toggle("Readable markdown copy (one file per meeting)", isOn: Binding(
                get: { appState.settings.backupIncludeMarkdown },
                set: { appState.settings.backupIncludeMarkdown = $0 }
            ))
            Toggle(isOn: Binding(
                get: { appState.settings.backupIncludeMedia },
                set: { appState.settings.backupIncludeMedia = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Audio & video recordings")
                    Text("Currently \(ByteCountFormatter.string(fromByteCount: audioUsageBytes, countStyle: .file)) — copied incrementally.")
                        .font(.caption).foregroundStyle(Color.appTextTertiary)
                }
            }
            Toggle("Back up automatically once a week", isOn: Binding(
                get: { appState.settings.backupAutoWeekly },
                set: { appState.settings.backupAutoWeekly = $0 }
            ))
        }
    }

    // MARK: - Back up now

    private var backupNowSection: some View {
        Section {
            if backup.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: backup.progress)
                    Text(phaseLabel(backup.phase))
                        .font(.caption).foregroundStyle(Color.appTextSecondary)
                }
            } else {
                Button {
                    Task {
                        await backup.runBackup(
                            destination: URL(fileURLWithPath: destinationPath),
                            includeMedia: appState.settings.backupIncludeMedia,
                            includeMarkdown: appState.settings.backupIncludeMarkdown
                        )
                        if case .done = backup.phase { appState.settings.lastBackupAt = Date() }
                    }
                } label: {
                    Label("Back Up Now", systemImage: "externaldrive.badge.timemachine")
                }
                .disabled(!hasDestination || appState.isRecording)

                if appState.isRecording {
                    Text("Backup is paused while a recording is in progress.")
                        .font(.caption).foregroundStyle(Color.appWarning)
                } else if !hasDestination {
                    Text("Choose a backup location first.")
                        .font(.caption).foregroundStyle(Color.appTextTertiary)
                }
            }

            if case .failed(let message) = backup.phase {
                Text(message).font(.caption).foregroundStyle(Color.appRecording)
            }

            if let last = appState.settings.lastBackupAt {
                Text("Last backup: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Color.appTextTertiary)
            } else {
                Text("No backup yet.").font(.caption).foregroundStyle(Color.appTextTertiary)
            }
        }
    }

    // MARK: - Restore

    private var restoreSection: some View {
        Section("Restore") {
            Button {
                chooseRestoreSource()
            } label: {
                Label("Restore from Backup…", systemImage: "arrow.clockwise")
            }
            Text("Restoring replaces all current data with the backup's, applied on the next launch. Your existing database is moved aside, not deleted.")
                .font(.caption).foregroundStyle(Color.appTextTertiary)
        }
    }

    // MARK: - Actions

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            appState.settings.backupDestinationPath = url.path
        }
    }

    private func chooseRestoreSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Validate"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let manifest = try await backup.validateBackup(at: url)
                restoreCandidate = url
                restoreManifest = manifest
            } catch {
                restoreError = error.localizedDescription
            }
        }
    }

    private func stageAndPromptRestart() {
        guard let url = restoreCandidate else { return }
        restoreManifest = nil
        Task {
            do {
                try await backup.stageRestore(from: url)
                showRestartPrompt = true
            } catch {
                restoreError = error.localizedDescription
            }
            restoreCandidate = nil
        }
    }

    private func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func phaseLabel(_ phase: BackupService.Phase) -> String {
        switch phase {
        case .idle: return "Idle"
        case .snapshotting: return "Snapshotting the database…"
        case .copyingFiles: return "Copying notes and attachments…"
        case .exportingMarkdown: return "Writing readable transcripts…"
        case .copyingMedia: return "Copying recordings…"
        case .verifying: return "Verifying…"
        case .done: return "Done"
        case .failed(let m): return m
        }
    }
}
