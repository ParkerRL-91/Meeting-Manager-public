import AVFoundation
import CoreAudio

/// Captures system audio output using Core Audio Taps (macOS 14.2+)
///
/// This taps into the audio output of call apps (Zoom, Teams, etc.)
/// to capture the remote participant's audio.
///
/// Requires Screen Recording permission in System Settings > Privacy & Security.
@available(macOS 14.2, *)
final class SystemAudioTap {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    /// Start capturing system audio from the specified process (or all system audio)
    func start(processID: pid_t? = nil) async throws {
        guard !isRunning else { return }

        // Create a process tap targeting call app audio
        let tapDescription: CATapDescription
        if let pid = processID {
            // Tap a specific process
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [AudioObjectID(pid)])
        } else {
            // Tap all system output (fallback)
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [AudioObjectID]())
        }

        // The tap UUID is used as its UID string when building the aggregate device.
        let tapUUID = UUID()
        tapDescription.name = "MeetingManager.SystemAudioTap"
        tapDescription.uuid = tapUUID

        // Create the hardware tap
        var tapObjectID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapObjectID)
        guard tapStatus == noErr else {
            throw AudioCaptureError.captureSetupFailed("Failed to create process tap: \(tapStatus)")
        }
        self.tapID = tapObjectID

        // Create aggregate device that includes the tap, identified by UUID string.
        let aggregateID = try createAggregateDevice(tapUID: tapUUID.uuidString)
        self.aggregateDeviceID = aggregateID

        // Give the aggregate device a moment to finish hardware negotiation
        // before installing the IO proc — avoids kAudioHardwareNotReadyError ('nrdy').
        try await Task.sleep(for: .milliseconds(300))

        // Set up IO proc to receive audio buffers
        try setupIOProc(deviceID: aggregateID)

        isRunning = true
    }

    /// Stop system audio capture
    func stop() {
        guard isRunning else { return }
        isRunning = false

        // Stop and destroy IO proc
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        // Destroy aggregate device
        if aggregateDeviceID != kAudioObjectUnknown {
            var deviceID = aggregateDeviceID
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioPlugInDestroyAggregateDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(
                UInt32(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &deviceID
            )
            aggregateDeviceID = kAudioObjectUnknown
        }

        // Destroy tap
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MeetingManager Aggregate",
            kAudioAggregateDeviceUIDKey as String: "com.meetingmanager.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                // kAudioSubTapUIDKey expects the tap's UUID string, not its AudioObjectID.
                [kAudioSubTapUIDKey as String: tapUID]
            ]
        ]

        var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard status == noErr else {
            throw AudioCaptureError.captureSetupFailed("Failed to create aggregate device: \(status)")
        }

        return aggregateDeviceID
    }

    private func setupIOProc(deviceID: AudioObjectID) throws {
        let callback = self

        let format = AVAudioFormat(
            standardFormatWithSampleRate: 16000,
            channels: 1
        )!

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) {
            _, inputData, inputTime, _, _ in

            let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let firstBuffer = bufferList.first,
                  let data = firstBuffer.mData else { return }
            let frameCount = firstBuffer.mDataByteSize / UInt32(MemoryLayout<Float>.size)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
            memcpy(pcmBuffer.floatChannelData?[0], data, Int(firstBuffer.mDataByteSize))

            let time = AVAudioTime(hostTime: inputTime.pointee.mHostTime)
            callback.onBuffer?(pcmBuffer, time)
        }

        guard status == noErr, let procID else {
            throw AudioCaptureError.captureSetupFailed("Failed to create IO proc: \(status)")
        }

        self.ioProcID = procID

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            throw AudioCaptureError.captureSetupFailed("Failed to start audio device: \(startStatus)")
        }
    }
}
