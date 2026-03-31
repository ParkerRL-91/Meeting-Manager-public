import AVFoundation
import ScreenCaptureKit
import os

/// Captures system audio output using ScreenCaptureKit (macOS 13+)
///
/// This captures audio from all apps (Zoom, Teams, browser calls, etc.)
/// to record what remote meeting participants say.
///
/// Requires Screen Recording permission in System Settings > Privacy & Security.
/// Even for audio-only capture, ScreenCaptureKit requires this permission.
@available(macOS 14.2, *)
final class SystemAudioTap: NSObject, SCStreamDelegate, SCStreamOutput {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Diagnostic callback for logging (set by AudioCaptureService)
    var onDiagnostic: ((String) -> Void)?

    private var stream: SCStream?
    private var isRunning = false
    private var bufferCount: Int = 0

    /// Target output format: 16kHz mono Float32 (matches mic capture pipeline)
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Start capturing system audio via ScreenCaptureKit.
    /// This captures all system audio output except our own app's audio.
    func start(processID: pid_t? = nil) async throws {
        guard !isRunning else { return }

        // Get available content for filtering
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            onDiagnostic?("DIAG:sys_tap ERROR getting shareable content: \(error.localizedDescription)")
            throw AudioCaptureError.captureSetupFailed("ScreenCaptureKit content unavailable: \(error.localizedDescription)")
        }

        guard let display = content.displays.first else {
            throw AudioCaptureError.captureSetupFailed("No display found for ScreenCaptureKit")
        }

        onDiagnostic?("DIAG:sys_tap found \(content.displays.count) displays, \(content.applications.count) apps")

        // Exclude our own app from capture to prevent feedback
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.meetingmanager.app"
        let excludedApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        onDiagnostic?("DIAG:sys_tap excluding \(excludedApps.count) own app instances (bundle: \(ownBundleID))")

        // Create filter: capture full display audio, excluding our app
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        // Configure for audio-only capture
        let config = SCStreamConfiguration()
        // Minimal video config (SCStream requires video, but we'll ignore it)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum
        // Audio config
        config.capturesAudio = true
        config.sampleRate = 48000       // Capture at native rate
        config.channelCount = 2         // Stereo system audio
        config.excludesCurrentProcessAudio = true  // Don't capture our own audio

        onDiagnostic?("DIAG:sys_tap configuring SCStream: audio=48kHz/2ch, excludeSelf=true")

        // Create stream
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        // Add audio output handler
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.meetingmanager.systemaudio", qos: .userInteractive))

        // Start capture
        do {
            try await stream.startCapture()
            self.stream = stream
            self.isRunning = true
            self.bufferCount = 0
            onDiagnostic?("DIAG:sys_tap SCStream started successfully")
        } catch {
            onDiagnostic?("DIAG:sys_tap SCStream start FAILED: \(error.localizedDescription)")
            throw AudioCaptureError.captureSetupFailed("SCStream start failed: \(error.localizedDescription). Check Screen Recording permission.")
        }
    }

    /// Stop system audio capture
    func stop() {
        guard isRunning else { return }
        isRunning = false

        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only process audio buffers
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }

        bufferCount += 1

        // Extract audio data from CMSampleBuffer
        guard let formatDesc = sampleBuffer.formatDescription else {
            if bufferCount <= 3 {
                onDiagnostic?("DIAG:sys_sckit #\(bufferCount) no format description")
            }
            return
        }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        let sampleRate = asbd?.mSampleRate ?? 48000
        let channels = asbd?.mChannelsPerFrame ?? 2

        // Get the audio buffer list
        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, blockBuffer in
                let bufferListPtr = audioBufferList.unsafePointer
                let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferListPtr))

                guard let firstBuffer = abl.first,
                      let data = firstBuffer.mData else { return }

                let totalBytes = Int(firstBuffer.mDataByteSize)
                let totalFloats = totalBytes / MemoryLayout<Float>.size
                let frameCount = totalFloats / Int(channels)

                let srcPtr = data.assumingMemoryBound(to: Float.self)

                // Diagnostic: log periodically
                if bufferCount <= 3 || bufferCount % 200 == 0 {
                    var sum: Float = 0
                    let checkN = min(100, totalFloats)
                    for i in 0..<checkN {
                        sum += srcPtr[i] * srcPtr[i]
                    }
                    let rawRMS = checkN > 0 ? sqrtf(sum / Float(checkN)) : 0
                    let samples = (0..<min(5, totalFloats)).map { String(format: "%.6f", srcPtr[$0]) }.joined(separator: ",")
                    onDiagnostic?("DIAG:sys_sckit #\(bufferCount) frames=\(frameCount) rate=\(sampleRate) ch=\(channels) rms=\(String(format: "%.6f", rawRMS)) samples=[\(samples)]")
                }

                // Mix to mono
                var monoSamples = [Float](repeating: 0, count: frameCount)
                if channels > 1 {
                    for frame in 0..<frameCount {
                        var sum: Float = 0
                        for ch in 0..<Int(channels) {
                            let idx = frame * Int(channels) + ch
                            if idx < totalFloats {
                                sum += srcPtr[idx]
                            }
                        }
                        monoSamples[frame] = sum / Float(channels)
                    }
                } else {
                    for i in 0..<frameCount {
                        monoSamples[i] = srcPtr[i]
                    }
                }

                // Downsample to 16kHz
                let ratio = 16000.0 / sampleRate
                let outputCount = Int(Double(frameCount) * ratio)
                guard outputCount > 0 else { return }

                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(outputCount)) else { return }
                pcmBuffer.frameLength = AVAudioFrameCount(outputCount)
                guard let outPtr = pcmBuffer.floatChannelData?[0] else { return }

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

                let time = AVAudioTime(hostTime: mach_absolute_time())
                onBuffer?(pcmBuffer, time)
            }
        } catch {
            if bufferCount <= 3 {
                onDiagnostic?("DIAG:sys_sckit #\(bufferCount) buffer extraction error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onDiagnostic?("DIAG:sys_tap SCStream stopped with error: \(error.localizedDescription)")
        Logger.audio.error("System audio stream stopped: \(error.localizedDescription)")
        isRunning = false
    }
}
