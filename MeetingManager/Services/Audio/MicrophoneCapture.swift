import AVFoundation
import os

/// Captures microphone input using AVAudioEngine
final class MicrophoneCapture {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// Raw (unconverted) buffer callback — for SFSpeechRecognizer which handles its own conversion.
    var onRawBuffer: ((AVAudioPCMBuffer) -> Void)?

    let engine = AVAudioEngine()
    private var isRunning = false
    private var converter: AVAudioConverter?
    private(set) var preferredInputDeviceID: String?

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
        inputNode.removeTap(onBus: 0)

        // Pass nil format — AVAudioEngine will use the hardware's native format.
        // We set up a persistent converter to downsample to 16kHz mono.
        inputNode.installTap(onBus: 0, bufferSize: 8192, format: nil) {
            [weak self] buffer, time in
            guard let self else { return }

            // Send raw buffer to speech recognizer (it handles its own format conversion)
            self.onRawBuffer?(buffer)

            // Lazy-init the converter on first buffer (now we know the actual hardware format)
            if self.converter == nil {
                self.converter = AVAudioConverter(from: buffer.format, to: self.targetFormat)
                let hwFmt = buffer.format
                Logger.audio.info("Mic tap format: \(hwFmt.sampleRate)Hz \(hwFmt.channelCount)ch → converter created")
            }

            if let converted = self.convert(buffer) {
                self.onBuffer?(converted, time)
            }
        }

        try engine.start()
        isRunning = true
        Logger.audio.info("MicrophoneCapture started (format: nil, converter will init on first buffer)")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        Logger.audio.info("MicrophoneCapture stopped")
    }

    // MARK: - Conversion

    /// Convert a buffer to 16kHz mono using the persistent converter.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // If already in target format, pass through
        if buffer.format.sampleRate == targetFormat.sampleRate
            && buffer.format.channelCount == targetFormat.channelCount {
            return buffer
        }

        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status == .haveData || status == .endOfStream, error == nil else {
            return nil
        }

        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }
}
