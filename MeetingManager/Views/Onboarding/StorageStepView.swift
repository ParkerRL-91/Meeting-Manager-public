import SwiftUI
import AppKit

/// Onboarding step that guarantees a writable location for meeting recordings
/// before the user can continue. It probes the location on appear — the common
/// case (default Application Support) is an instant green check — and on failure
/// the user picks a folder via the system open panel (which is also how macOS
/// grants access). Continue stays disabled until a real write succeeds, so a
/// user can never finish setup with a broken recording destination.
struct StorageStepView: View {
    let onContinue: () -> Void

    private enum Status: Equatable {
        case checking
        case writable(URL)
        case failed(URL, String)
    }

    @State private var status: Status = .checking
    @State private var isCustom: Bool = RecordingStorage.shared.customDirectory != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    explanation
                    locationCard
                    if case .failed = status { troubleshooting }
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: recheck)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.appAccent)
                Text("Where recordings are saved")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.appTextPrimary)
            }
            Text("Meeting Manager has to be able to write audio to disk before it can record.")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
        }
    }

    private var explanation: some View {
        Text("Recordings are saved to your Mac and transcribed on-device. The default location works for almost everyone — you only need to change it if the check below fails, or if you'd rather keep recordings in a folder you can browse to.")
            .font(.body)
            .foregroundStyle(Color.appTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var locationCard: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(currentPath)
                    .font(.callout)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLabel
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Change…") { chooseFolder() }
                if isCustom {
                    Button("Use default") { useDefault() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
        }
        .padding(14)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .writable:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .checking:
            Text("Checking…")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        case .writable:
            Text("Ready to record — this folder is writable.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        case .failed(_, let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var troubleshooting: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text("This location can't be written to.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Text("This usually means the folder is owned by another account (common after migrating Macs or restoring a backup). Pick a folder you own — your Documents folder, or a new folder anywhere on your Mac. Choosing it also grants Meeting Manager permission to write there.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    chooseFolder()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                        Text("Choose a folder…").fontWeight(.medium)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.appAccent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            if case .writable = status {
                Button {
                    revealInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appTextSecondary)
            }
            Spacer()
            Button("Continue") { onContinue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.appAccent)
                .disabled(!isWritable)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
    }

    // MARK: - State helpers

    private var isWritable: Bool {
        if case .writable = status { return true }
        return false
    }

    private var currentPath: String {
        switch status {
        case .checking: return RecordingStorage.shared.preferredDirectory().path
        case .writable(let url), .failed(let url, _): return url.path
        }
    }

    // MARK: - Actions

    private func recheck() {
        let dir = RecordingStorage.shared.preferredDirectory()
        if let error = RecordingStorage.probe(dir) {
            status = .failed(dir, error.localizedDescription)
        } else {
            status = .writable(dir)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder where Meeting Manager can save audio recordings."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RecordingStorage.shared.customDirectory = url
        isCustom = true
        recheck()
    }

    private func useDefault() {
        RecordingStorage.shared.customDirectory = nil
        isCustom = false
        recheck()
    }

    private func revealInFinder() {
        let url = RecordingStorage.shared.preferredDirectory()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
