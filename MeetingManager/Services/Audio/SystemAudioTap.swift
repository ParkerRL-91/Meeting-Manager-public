import AVFoundation
import CoreAudio

/// Captures system audio output using Core Audio Taps (macOS 14.4+)
///
/// This taps into the audio output of call apps (Zoom, Teams, etc.)
/// to capture the remote participant's audio.
///
/// Requires Screen Recording permission in System Settings > Privacy & Security.
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
        var tapDescription: CATapDescription
        if let pid = processID {
            // Tap a specific process
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [pid])
        } else {
            // Tap all system output (fallback)
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }

        tapDescription.name = "MeetingManager.SystemAudioTap" as CFString
        tapDescription.uuid = UUID()

        // Create the hardware tap
        var tapObjectID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(&tapDescription, &tapObjectID)
        guard tapStatus == noErr else {
            throw AudioCaptureError.captureSetupFailed("Failed to create process tap: \(tapStatus)")
        }
        self.tapID = tapObjectID

        // Create aggregate device that includes the tap
        let aggregateID = try createAggregateDevice(tapID: tapObjectID)
        self.aggregateDeviceID = aggregateID

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
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioPlugInDestroyAggregateDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(
                kAudioObjectSystemObject,
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

    private func createAggregateDevice(tapID: AudioObjectID) throws -> AudioObjectID {
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MeetingManager Aggregate",
            kAudioAggregateDeviceUIDKey as String: "com.meetingmanager.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapID
                ]
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

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) {
            _, inputData, inputTime, _, _ in

            guard let bufferList = inputData?.pointee else { return }

            let format = AVAudioFormat(
                standardFormatWithSampleRate: 16000,
                channels: 1
            )!

            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &bufferList) else {
                return
            }

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

// MARK: - CATapDescription (available macOS 14.4+)

struct CATapDescription {
    var name: CFString = "" as CFString
    var uuid: UUID = UUID()
    private var processes: [pid_t]
    private var isExclusive: Bool

    init(stereoMixdownOfProcesses processes: [pid_t]) {
        self.processes = processes
        self.isExclusive = false
    }

    init(stereoGlobalTapButExcludeProcesses excluded: [pid_t]) {
        self.processes = excluded
        self.isExclusive = true
    }
}
