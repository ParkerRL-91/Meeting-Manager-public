import SwiftUI
import AVFoundation
import os

/// Settings view for audio input device selection and permission management.
struct AudioSettingsView: View {

    // MARK: - State

    @Environment(AppState.self) private var appState

    @State private var availableDevices: [AVCaptureDevice] = []
    @State private var hasMicPermission: Bool = false
    @State private var hasScreenRecordingPermission: Bool = false

    // PRJ-016 audio retention
    @State private var currentUsageBytes: Int64 = 0
    @State private var proposedRetention: Int = 0
    @State private var reclaimableBytes: Int64 = 0
    @State private var showPruneConfirm = false
    @State private var pruneResultMessage: String?

    // TASK-135 compression backfill
    @State private var compression = AudioArchiveService.Preview()
    @State private var showCompressConfirm = false

    private let audioManager = AudioSessionManager()

    /// The microphone auto-detection would currently pick.
    private var autoDetectedDeviceName: String {
        audioManager.bestInputDevice()?.localizedName ?? "system default"
    }

    // MARK: - Body

    var body: some View {
        Form {
            inputDeviceSection
            storageSection
            videoCaptureSection
            permissionsSection
        }
        .formStyle(.grouped)
        .onAppear(perform: loadState)
        .onChange(of: appState.audioCompressionResult) { _, _ in refreshUsage() }
        .alert("Remove old audio?", isPresented: $showPruneConfirm) {
            Button("Cancel", role: .cancel) { }
            Button(pruneConfirmButtonTitle) {
                appState.settings.audioRetentionDays = proposedRetention
                Task {
                    let freed = await appState.runAudioRetentionSweepNow()
                    let usage = await Task.detached { AudioRetention.currentAudioUsageBytes() }.value
                    await MainActor.run {
                        currentUsageBytes = usage
                        pruneResultMessage = freed > 0
                            ? "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) of audio."
                            : "Automatic cleanup is on. Nothing needed removing yet."
                    }
                }
            }
        } message: {
            Text(pruneConfirmMessage)
        }
        .alert("Compress existing recordings?", isPresented: $showCompressConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Compress now") { appState.startAudioCompressionBackfill() }
        } message: {
            Text(compressConfirmMessage)
        }
    }

    // MARK: - Sections

    private var inputDeviceSection: some View {
        @Bindable var appState = appState
        return Section {
            Toggle("Override microphone selection", isOn: Binding(
                get: { appState.settings.micOverrideEnabled },
                set: { newValue in
                    appState.settings.micOverrideEnabled = newValue
                    // Pre-fill with the auto-detected device so enabling the
                    // override starts from a sensible, working selection.
                    if newValue, appState.settings.micOverrideDeviceID.isEmpty,
                       let best = audioManager.bestInputDevice() {
                        appState.settings.micOverrideDeviceID = best.uniqueID
                    }
                }
            ))

            if appState.settings.micOverrideEnabled {
                if availableDevices.isEmpty {
                    Text("No audio input devices found")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Microphone", selection: Binding(
                        get: { appState.settings.micOverrideDeviceID },
                        set: { appState.settings.micOverrideDeviceID = $0 }
                    )) {
                        ForEach(availableDevices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                }
            } else {
                Label("Automatically using \(autoDetectedDeviceName)", systemImage: "wand.and.stars")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Input Device")
        } footer: {
            Text(appState.settings.micOverrideEnabled
                 ? "Recording from the microphone you selected. If it's unplugged or can't capture audio, Meeting Manager falls back to automatic selection so recordings are never silent."
                 : "Meeting Manager automatically selects the best available microphone and adapts when you plug or unplug devices. Turn on the override only if you need to force a specific microphone.")
        }
    }

    private var storageSection: some View {
        Section {
            Picker("Keep audio for", selection: Binding(
                get: { appState.settings.audioRetentionDays },
                set: { handleRetentionChange(to: $0) }
            )) {
                Text("Forever").tag(0)
                Text("30 days").tag(30)
                Text("60 days").tag(60)
                Text("90 days").tag(90)
                Text("180 days").tag(180)
                Text("1 year").tag(365)
            }

            if let msg = pruneResultMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            compressionRow
        } header: {
            Text("Audio storage")
        } footer: {
            Text(storageFooterText)
        }
    }

    /// TASK-135: one-time recompression of the existing library. New recordings
    /// are compressed automatically once their transcript is finished, so this
    /// only exists for meetings recorded before that shipped.
    private var compressionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showCompressConfirm = true
            } label: {
                Label("Compress existing recordings", systemImage: "arrow.down.circle")
            }
            .disabled(appState.isCompressingAudio || compression.meetings == 0)

            if let progress = appState.audioCompressionProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Compressed \(progress.done) of \(progress.total) meetings…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Stop") { appState.stopAudioCompressionBackfill() }
                        .controlSize(.small)
                }
            } else if let result = appState.audioCompressionResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(compressionIdleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var compressionIdleText: String {
        if compression.meetings == 0 {
            return "Every recording is already stored in the compressed format. New recordings are compressed automatically once their transcript is finished."
        }
        guard compression.bytes > 0 else {
            // Files are compressed but their meeting records still name the old
            // ones — an interrupted run. Running it again only fixes the records.
            return "A previous compression run was interrupted. Running it again finishes updating \(compression.meetings) meeting record(s); no audio is re-encoded."
        }
        return "\(ByteCountFormatter.string(fromByteCount: compression.bytes, countStyle: .file)) of older recordings across \(compression.meetings) meetings are still stored uncompressed. Compressing them keeps the audio lossless and playable while using about a fifth of the space."
    }

    private var compressConfirmMessage: String {
        let size = ByteCountFormatter.string(fromByteCount: compression.bytes, countStyle: .file)
        return "Meeting Manager will rewrite \(size) of recordings as compressed lossless audio, one meeting at a time in the background. Playback, re-transcription, and speaker re-analysis keep working, and each original file is only removed after its compressed copy is verified. Recording pauses the run; you can stop it at any time."
    }

    private var storageFooterText: String {
        let usage = ByteCountFormatter.string(fromByteCount: currentUsageBytes, countStyle: .file)
        if appState.settings.audioRetentionDays == 0 {
            return "Recorded audio currently uses \(usage). Audio is kept forever. Choose a shorter window to automatically remove old recordings and reclaim space; transcripts, summaries, and notes are always kept."
        }
        return "Recorded audio currently uses \(usage). Recordings older than \(appState.settings.audioRetentionDays) days are removed automatically; transcripts, summaries, and notes are kept."
    }

    private var pruneConfirmButtonTitle: String {
        reclaimableBytes > 0
            ? "Free \(ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)) now"
            : "Turn on automatic cleanup"
    }

    private var pruneConfirmMessage: String {
        let policy = "Meeting Manager will remove audio older than \(proposedRetention) days from now on, including each time the app starts. You can change this anytime here."
        if reclaimableBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
            return "This frees about \(size) now. Audio for those meetings can no longer be played back or re-transcribed; their transcripts, summaries, and notes are kept. \(policy)"
        }
        return "There is no audio old enough to remove yet. \(policy)"
    }

    /// Apply a retention change. A longer window or Forever deletes nothing, so
    /// it applies immediately. A shorter finite window (or leaving Forever for a
    /// finite one) would prune audio, so confirm with the reclaimable size first
    /// and only commit + sweep on the user's confirmation.
    private func handleRetentionChange(to new: Int) {
        let old = appState.settings.audioRetentionDays
        guard new != old else { return }
        let destructive = new != 0 && (old == 0 || new < old)
        if !destructive {
            appState.settings.audioRetentionDays = new
            return
        }
        proposedRetention = new
        pruneResultMessage = nil
        Task {
            let bytes = await AudioRetention.reclaimableBytes(database: appState.database, retentionDays: new)
            await MainActor.run {
                reclaimableBytes = bytes
                showPruneConfirm = true
            }
        }
    }

    // MARK: - Video capture (relocated from OnDeviceSettingsView / TASK-080)

    @ViewBuilder
    private var videoCaptureSection: some View {
        if #available(macOS 15.0, *) {
            Section {
                Toggle("Record meeting video", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "video.captureEnabled") },
                    set: { UserDefaults.standard.set($0, forKey: "video.captureEnabled") }
                ))
            } header: {
                Text("Video Capture")
            } footer: {
                Text("When on, Meeting Manager records the video of the meeting window you're in (on-device only, never uploaded), so you can revisit what was shown. Off by default. Old videos are removed automatically after the retention period. Audio capture is unaffected either way.")
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            // Microphone permission
            HStack {
                Label {
                    Text("Microphone Access")
                } icon: {
                    Image(systemName: hasMicPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(hasMicPermission ? Color.appSuccess : .red)
                }

                Spacer()

                if hasMicPermission {
                    Text("Granted")
                        .font(.caption)
                        .foregroundStyle(Color.appSuccess)
                } else {
                    Button("Request Permission") {
                        requestMicPermission()
                    }
                    .controlSize(.small)
                }
            }

            // Screen recording permission
            HStack {
                Label {
                    Text("Screen Recording")
                } icon: {
                    Image(systemName: hasScreenRecordingPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(hasScreenRecordingPermission ? Color.appSuccess : .red)
                }

                Spacer()

                if hasScreenRecordingPermission {
                    Text("Granted")
                        .font(.caption)
                        .foregroundStyle(Color.appSuccess)
                } else {
                    Button("Open System Settings") {
                        openScreenRecordingSettings()
                    }
                    .controlSize(.small)
                }
            }

            if !hasMicPermission {
                Button("Open System Settings") {
                    openMicrophoneSettings()
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Microphone access is required to capture meeting audio. Screen recording permission is needed to capture system audio from video call apps.")
        }
    }

    // MARK: - Actions

    private func loadState() {
        availableDevices = audioManager.availableInputDevices()
        hasScreenRecordingPermission = audioManager.hasScreenRecordingPermission()

        // Check current mic permission status
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicPermission = (status == .authorized)

        refreshUsage()
    }

    /// Both figures stat every recording, so they're read off the main actor.
    private func refreshUsage() {
        Task {
            let usage = await Task.detached { AudioRetention.currentAudioUsageBytes() }.value
            let preview = await AudioArchiveService.compressionPreview(database: appState.database)
            await MainActor.run {
                currentUsageBytes = usage
                compression = preview
            }
        }
    }

    private func requestMicPermission() {
        Task {
            let granted = await audioManager.requestMicrophonePermission()
            await MainActor.run {
                hasMicPermission = granted
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Preview

// #Preview("Audio Settings") {
//     AudioSettingsView()
//         .frame(width: 500, height: 400)
// }
