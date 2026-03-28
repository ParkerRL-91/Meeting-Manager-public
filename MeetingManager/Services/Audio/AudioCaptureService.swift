import AVFoundation
import Combine

/// Orchestrates mic + system audio capture for meeting recording
final class AudioCaptureService: ObservableObject {
    @Published var isCapturing = false
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0

    private let micCapture = MicrophoneCapture()
    private let systemTap = SystemAudioTap()
    private let bufferManager = AudioBufferManager()
    private let sessionManager = AudioSessionManager()

    private var audioFileURL: URL?

    /// Start capturing audio from both mic and system
    func startCapture(meetingId: String) async throws {
        guard !isCapturing else { return }

        // Verify permissions
        guard await sessionManager.requestMicrophonePermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Set up audio file for recording
        let audioDir = try audioDirectory()
        let fileURL = audioDir.appendingPathComponent("\(meetingId).wav")
        audioFileURL = fileURL

        try bufferManager.prepareForRecording(outputURL: fileURL)

        // Start mic capture
        micCapture.onBuffer = { [weak self] buffer, time in
            self?.bufferManager.appendMicBuffer(buffer, at: time)
            self?.updateMicLevel(buffer)
        }
        try micCapture.start()

        // Start system audio capture (for remote participant audio)
        systemTap.onBuffer = { [weak self] buffer, time in
            self?.bufferManager.appendSystemBuffer(buffer, at: time)
            self?.updateSystemLevel(buffer)
        }
        try await systemTap.start()

        await MainActor.run {
            isCapturing = true
        }
    }

    /// Stop all audio capture
    func stopCapture() -> URL? {
        micCapture.stop()
        systemTap.stop()
        bufferManager.finishRecording()

        Task { @MainActor in
            isCapturing = false
            micLevel = 0
            systemLevel = 0
        }

        return audioFileURL
    }

    /// Get the buffer manager for the transcription service
    var transcriptionBuffer: AudioBufferManager {
        bufferManager
    }

    // MARK: - Private

    private func audioDirectory() throws -> URL {
        let url = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingManager/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func updateMicLevel(_ buffer: AVAudioPCMBuffer) {
        let level = buffer.rmsLevel
        Task { @MainActor in
            self.micLevel = level
        }
    }

    private func updateSystemLevel(_ buffer: AVAudioPCMBuffer) {
        let level = buffer.rmsLevel
        Task { @MainActor in
            self.systemLevel = level
        }
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case deviceNotFound
    case captureSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required to record meetings."
        case .systemAudioPermissionDenied:
            return "Screen Recording permission is required to capture remote audio."
        case .deviceNotFound:
            return "Audio device not found."
        case .captureSetupFailed(let reason):
            return "Audio capture setup failed: \(reason)"
        }
    }
}

// MARK: - AVAudioPCMBuffer Extension

extension AVAudioPCMBuffer {
    var rmsLevel: Float {
        guard let channelData = floatChannelData, frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<Int(frameLength) {
            sum += samples[i] * samples[i]
        }
        let rms = sqrtf(sum / Float(frameLength))
        return min(max(rms, 0), 1)
    }
}
