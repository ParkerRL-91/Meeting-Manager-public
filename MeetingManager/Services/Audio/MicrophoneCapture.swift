import AVFoundation
import os

/// Captures microphone input using AVAudioEngine
final class MicrophoneCapture {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private let engine = AVAudioEngine()
    private var isRunning = false
    private(set) var preferredInputDeviceID: String?

    /// Store a preferred input device ID to use when starting capture.
    func configure(inputDeviceID: String) {
        self.preferredInputDeviceID = inputDeviceID
    }

    /// Target format: 16kHz mono Float32 (WhisperKit's expected input)
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode

        // Remove any leftover tap from a previous session to avoid
        // "tap already installed" NSException.
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw AudioCaptureError.deviceNotFound
        }

        Logger.audio.info("Mic hardware format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // Pass nil for format to let AVAudioEngine auto-negotiate with the
        // hardware. This avoids NSException crashes from format mismatches
        // (e.g. when the hardware format doesn't support the requested layout).
        // We convert to 16kHz mono in the callback instead.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
            [weak self] buffer, time in
            guard let self else { return }
            if let converted = self.convertBuffer(buffer, from: buffer.format) {
                self.onBuffer?(converted, time)
            }
        }

        try engine.start()
        isRunning = true
        Logger.audio.info("MicrophoneCapture started")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        Logger.audio.info("MicrophoneCapture stopped")
    }

    // MARK: - Private

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        // If already in target format, return as-is
        if sourceFormat.sampleRate == targetFormat.sampleRate
            && sourceFormat.channelCount == targetFormat.channelCount {
            return buffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else {
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else {
            return nil
        }

        return outputBuffer
    }
}
