import AVFoundation
import os

/// Captures microphone input using AVAudioEngine.
///
/// Feeds raw hardware-format audio to onRawBuffer (for SFSpeechRecognizer),
/// and manually downsampled 16kHz mono Float32 to onBuffer (for WhisperKit + WAV recording).
///
/// Uses simple linear interpolation for downsampling instead of AVAudioConverter,
/// which produces near-silent output in real-time streaming scenarios.
final class MicrophoneCapture {
    /// 16kHz mono Float32 buffers for WhisperKit + WAV recording.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// Raw hardware-format buffers for SFSpeechRecognizer.
    var onRawBuffer: ((AVAudioPCMBuffer) -> Void)?

    let engine = AVAudioEngine()
    private var isRunning = false
    private(set) var preferredInputDeviceID: String?

    /// Target format: 16kHz mono Float32.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    func configure(inputDeviceID: String) {
        self.preferredInputDeviceID = inputDeviceID
    }

    func start() throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw AudioCaptureError.deviceNotFound
        }

        let hwRate = hwFormat.sampleRate
        let hwChannels = Int(hwFormat.channelCount)
        Logger.audio.info("Mic: \(hwRate)Hz \(hwChannels)ch → downsampling to 16kHz mono")

        inputNode.installTap(onBus: 0, bufferSize: 8192, format: nil) {
            [weak self] buffer, time in
            guard let self else { return }

            // Send raw buffer for SFSpeechRecognizer
            self.onRawBuffer?(buffer)

            // Downsample to 16kHz mono using simple linear interpolation
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            // Mix all channels to mono
            var monoSamples = [Float](repeating: 0, count: frameCount)
            for ch in 0..<hwChannels {
                let chPtr = channelData[ch]
                for i in 0..<frameCount {
                    monoSamples[i] += chPtr[i]
                }
            }
            if hwChannels > 1 {
                let scale = 1.0 / Float(hwChannels)
                for i in 0..<frameCount {
                    monoSamples[i] *= scale
                }
            }

            // Resample from hwRate to 16000 Hz
            let ratio = 16000.0 / hwRate
            let outputCount = Int(Double(frameCount) * ratio)
            guard outputCount > 0 else { return }

            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat,
                                                    frameCapacity: AVAudioFrameCount(outputCount)) else { return }
            outBuffer.frameLength = AVAudioFrameCount(outputCount)
            guard let outPtr = outBuffer.floatChannelData?[0] else { return }

            // Linear interpolation resampling
            for i in 0..<outputCount {
                let srcPos = Double(i) / ratio
                let srcIdx = Int(srcPos)
                let frac = Float(srcPos - Double(srcIdx))

                if srcIdx + 1 < frameCount {
                    outPtr[i] = monoSamples[srcIdx] * (1 - frac) + monoSamples[srcIdx + 1] * frac
                } else if srcIdx < frameCount {
                    outPtr[i] = monoSamples[srcIdx]
                }
            }

            self.onBuffer?(outBuffer, time)
        }

        try engine.start()
        isRunning = true
        Logger.audio.info("MicrophoneCapture started (manual downsample to 16kHz)")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        Logger.audio.info("MicrophoneCapture stopped")
    }
}
