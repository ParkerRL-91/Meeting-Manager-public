import AVFoundation
import Foundation
import Speech
import os

/// Real-time transcription engine using Apple's SFSpeechRecognizer.
///
/// Unlike WhisperKit (which needs 30-second chunks), SFSpeechRecognizer is designed
/// for streaming audio and produces results in real-time as speech is detected.
/// It uses Apple's on-device speech model — no internet required on macOS 13+.
///
/// This replaces the StreamingTranscriber + WhisperKit pipeline for live transcription.
/// WhisperKit remains available for post-recording batch transcription if needed.
@MainActor
final class AppleSpeechTranscriber {

    // MARK: - Published State

    private(set) var isActive = false
    private(set) var segmentCount: Int = 0
    private(set) var lastError: Error?

    // MARK: - Private

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// The meeting ID currently being transcribed.
    private var currentMeetingId: String?

    /// Repository for persisting transcript segments.
    private var repository: TranscriptRepository?

    /// Track the last result length to only save new text.
    private var lastSavedTranscriptLength: Int = 0

    /// Accumulated segments to avoid duplicates.
    private var savedSegmentTexts: Set<String> = []

    // MARK: - Init

    init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Lifecycle

    /// Start real-time transcription from the given audio engine's input node.
    /// Call this AFTER the audio engine is already started.
    func start(
        meetingId: String,
        audioEngine: AVAudioEngine,
        repository: TranscriptRepository
    ) {
        guard !isActive else {
            Logger.transcription.warning("AppleSpeechTranscriber already active")
            return
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            Logger.transcription.error("SFSpeechRecognizer not available")
            fileLog("SFSpeechRecognizer not available on this system")
            return
        }

        self.currentMeetingId = meetingId
        self.repository = repository
        self.lastSavedTranscriptLength = 0
        self.savedSegmentTexts = []
        self.segmentCount = 0
        self.lastError = nil

        // Create the recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true  // Force on-device — no network needed
        // request.addsPunctuation = true  // Available on newer macOS

        self.recognitionRequest = request

        // Install a tap on the audio engine's input node to feed audio to the recognizer.
        // The engine is already running (started by AudioCaptureService).
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install a SECOND tap on bus 1 for speech recognition (bus 0 is used by MicrophoneCapture).
        // Actually, we can't install two taps on the same bus. Instead, we'll feed audio
        // from the MicrophoneCapture's onBuffer callback.
        // For now, install tap on bus 0 with nil format (the engine handles conversion).
        // We need to coordinate with MicrophoneCapture...

        // ALTERNATIVE: Feed the recognition request manually from the capture callback.
        // This avoids conflicting taps.

        fileLog("Starting SFSpeechRecognizer for meeting \(meetingId)")

        // Start the recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error)
            }
        }

        isActive = true
        Logger.transcription.info("AppleSpeechTranscriber started for meeting \(meetingId)")
        fileLog("AppleSpeechTranscriber STARTED")
    }

    /// Feed an audio buffer to the speech recognizer.
    /// Called from MicrophoneCapture's onBuffer callback.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    /// Stop transcription.
    func stop() {
        guard isActive else { return }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isActive = false
        currentMeetingId = nil

        let count = self.segmentCount
        Logger.transcription.info("AppleSpeechTranscriber stopped. Total segments: \(count)")
        fileLog("AppleSpeechTranscriber STOPPED, \(count) segments saved")
    }

    // MARK: - Result Handling

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            Logger.transcription.error("Speech recognition error: \(error.localizedDescription)")
            fileLog("Recognition error: \(error.localizedDescription)")
            self.lastError = error
            self.isActive = false  // Mark as inactive so fallback can trigger
            fileLog("Task completed with error — marked inactive for fallback")
            return
        }

        guard let result else { return }

        // Process each transcription segment from the result
        let segments = result.bestTranscription.segments

        for segment in segments {
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Avoid saving duplicate segments
            let segmentKey = "\(segment.timestamp)_\(text)"
            guard !savedSegmentTexts.contains(segmentKey) else { continue }
            savedSegmentTexts.insert(segmentKey)

            guard let meetingId = currentMeetingId, let repo = repository else { continue }

            let transcript = Transcript(
                meetingId: meetingId,
                speakerLabel: "mic",
                text: text,
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration,
                confidence: Double(segment.confidence)
            )

            segmentCount += 1

            // Persist to database
            Task {
                do {
                    try await repo.saveBatch([transcript])
                } catch {
                    Logger.transcription.error("Failed to save transcript: \(error.localizedDescription)")
                }
            }

            if self.segmentCount <= 3 || self.segmentCount % 10 == 0 {
                fileLog("Segment #\(self.segmentCount): \"\(text)\" (conf: \(segment.confidence))")
            }
        }
    }

    // MARK: - File Logging

    private func fileLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] AppleSpeech: \(message)\n"
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingManager/app.log")
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }
}
