// decode_probe.swift — AVFoundation ground-truth probe for the TASK-135
// audio-format evaluation (Phase 0).
//
// Standalone: compiled with swiftc, NOT part of the SPM package.
//   swiftc -O -o decode_probe decode_probe.swift
//
// Every subcommand prints a single JSON object on stdout and exits 0 on
// success, 1 on failure (with {"error": ...} on stdout).
//
// Subcommands:
//   info    <file>
//       AVAudioFile view of the file: decoded frame length, sample rate,
//       channel count, processing/file format. This is what every app
//       consumer sees, so `length` is the sample-parity kill criterion.
//
//   dump    <in> <out.f32>
//       Decode via AVAudioFile into a headerless Float32 blob. Exercises the
//       exact path SpeakerAttribution / FluidAudio / voice fingerprints use.
//
//   encode  --api <avaudiofile|extaudiofile> --codec <aac|alac>
//           [--bitrate N] <in> <out.m4a>
//       Encode with a real AVFoundation writing API (not afconvert), because
//       the shipping AudioArchiveService will use one of these. Reports the
//       decoded round-trip length so priming/padding behaviour is visible.
//
//   beeps   <out.wav> --minutes N [--period S]
//       Generate the seek fixture: 16 kHz mono Float32 WAV, 40 ms 1 kHz
//       beeps at known offsets over low-level pink-ish noise.
//
//   seek    <file> --times t1,t2,...
//       For each timestamp, seek with AVAssetReader on an AVURLAsset created
//       with AVURLAssetPreferPreciseDurationAndTimingKey and measure the beep
//       onset error in milliseconds.

import AVFoundation
import Foundation

// ─── JSON output ─────────────────────────────────────────────────────────────

func emit(_ dict: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    emit(["error": message])
    exit(1)
}

// ─── Arg parsing ─────────────────────────────────────────────────────────────

var args = Array(CommandLine.arguments.dropFirst())
guard let subcommand = args.first else {
    fail("usage: decode_probe <info|dump|encode|beeps|seek> ...")
}
args.removeFirst()

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

// ─── Shared helpers ──────────────────────────────────────────────────────────

func openForReading(_ path: String) -> AVAudioFile {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
        fail("cannot open for reading: \(path)")
    }
    return file
}

/// Decode an entire file through AVAudioFile's processing format (Float32).
/// Reads in chunks so 2-hour files don't need one giant buffer.
func decodeFloat32(_ path: String) -> (samples: [Float], sampleRate: Double, channels: Int) {
    let file = openForReading(path)
    let format = file.processingFormat
    let chunk: AVAudioFrameCount = 1 << 18
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
        fail("cannot allocate buffer for \(path)")
    }
    var out = [Float]()
    out.reserveCapacity(Int(file.length))
    while true {
        buffer.frameLength = 0
        do { try file.read(into: buffer, frameCount: chunk) } catch { break }
        if buffer.frameLength == 0 { break }
        guard let channelData = buffer.floatChannelData else { fail("non-float processing format for \(path)") }
        out.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
    return (out, format.sampleRate, Int(format.channelCount))
}

func formatDescription(_ format: AVAudioFormat) -> [String: Any] {
    let asbd = format.streamDescription.pointee
    var fourCC = asbd.mFormatID.bigEndian
    let idString = withUnsafeBytes(of: &fourCC) { String(bytes: $0, encoding: .ascii) ?? "?" }
    return [
        "sampleRate": format.sampleRate,
        "channels": Int(format.channelCount),
        "formatID": idString,
        "bitsPerChannel": Int(asbd.mBitsPerChannel),
        "bytesPerFrame": Int(asbd.mBytesPerFrame),
        "framesPerPacket": Int(asbd.mFramesPerPacket),
        "isInterleaved": format.isInterleaved,
        "commonFormat": format.commonFormat.rawValue,
    ]
}

// ─── info ────────────────────────────────────────────────────────────────────

func runInfo() {
    guard let path = args.first else { fail("info requires a file path") }
    let file = openForReading(path)
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
    emit([
        "path": path,
        "length": file.length,
        "framePosition": file.framePosition,
        "fileSizeBytes": size ?? -1,
        "processingFormat": formatDescription(file.processingFormat),
        "fileFormat": formatDescription(file.fileFormat),
        "durationSeconds": Double(file.length) / file.processingFormat.sampleRate,
    ])
}

// ─── dump ────────────────────────────────────────────────────────────────────

func runDump() {
    guard args.count >= 2 else { fail("dump requires <in> <out.f32>") }
    let (samples, sampleRate, channels) = decodeFloat32(args[0])
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    do { try data.write(to: URL(fileURLWithPath: args[1])) } catch { fail("write failed: \(error)") }
    emit([
        "in": args[0], "out": args[1],
        "frames": samples.count, "sampleRate": sampleRate, "channels": channels,
    ])
}

// ─── encode ──────────────────────────────────────────────────────────────────

/// Write via AVAudioFile(forWriting:settings:) — the highest-level API, the one
/// a Swift service would reach for first.
func encodeViaAVAudioFile(input: String, output: String, settings: [String: Any]) {
    let inFile = openForReading(input)
    let outURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outURL)
    guard let outFile = try? AVAudioFile(forWriting: outURL, settings: settings) else {
        fail("AVAudioFile(forWriting:) rejected settings \(settings)")
    }
    let chunk: AVAudioFrameCount = 1 << 16
    guard let buffer = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: chunk) else {
        fail("buffer alloc failed")
    }
    while true {
        buffer.frameLength = 0
        do { try inFile.read(into: buffer, frameCount: chunk) } catch { break }
        if buffer.frameLength == 0 { break }
        do { try outFile.write(from: buffer) } catch { fail("write failed: \(error)") }
    }
}

/// Write via ExtAudioFile — the C API. Kept as a separate candidate because it
/// exposes the codec/container plumbing directly and may handle gapless
/// priming metadata differently from AVAudioFile.
func encodeViaExtAudioFile(input: String, output: String, fileType: AudioFileTypeID,
                           outputASBD: inout AudioStreamBasicDescription, bitrate: Int?) {
    let inFile = openForReading(input)
    let clientFormat = inFile.processingFormat
    let outURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outURL)

    var extRef: ExtAudioFileRef?
    var status = ExtAudioFileCreateWithURL(
        outURL as CFURL, fileType, &outputASBD, nil,
        AudioFileFlags.eraseFile.rawValue, &extRef
    )
    guard status == noErr, let ext = extRef else {
        fail("ExtAudioFileCreateWithURL failed: \(status)")
    }

    var clientASBD = clientFormat.streamDescription.pointee
    status = ExtAudioFileSetProperty(
        ext, kExtAudioFileProperty_ClientDataFormat,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD
    )
    guard status == noErr else { fail("set ClientDataFormat failed: \(status)") }

    if let bitrate {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        if ExtAudioFileGetProperty(ext, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr,
           let converter {
            var rate = UInt32(bitrate)
            let setStatus = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                                      UInt32(MemoryLayout<UInt32>.size), &rate)
            if setStatus != noErr {
                FileHandle.standardError.write("warn: kAudioConverterEncodeBitRate -> \(setStatus)\n".data(using: .utf8)!)
            }
            // A zero-length ConverterConfig write tells ExtAudioFile to re-read
            // the converter's settings after we mutated it directly.
            var dummy: UInt32 = 0
            _ = withUnsafePointer(to: &dummy) {
                ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ConverterConfig, 0, UnsafeRawPointer($0))
            }
        }
    }

    let chunk: AVAudioFrameCount = 1 << 16
    guard let buffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: chunk) else {
        fail("buffer alloc failed")
    }
    while true {
        buffer.frameLength = 0
        do { try inFile.read(into: buffer, frameCount: chunk) } catch { break }
        if buffer.frameLength == 0 { break }
        var abl = buffer.mutableAudioBufferList.pointee
        let writeStatus = withUnsafeMutablePointer(to: &abl) { pointer in
            ExtAudioFileWrite(ext, buffer.frameLength, pointer)
        }
        guard writeStatus == noErr else { fail("ExtAudioFileWrite failed: \(writeStatus)") }
    }
    ExtAudioFileDispose(ext)
}

func runEncode() {
    let api = flag("api") ?? "avaudiofile"
    let codec = flag("codec") ?? "aac"
    let bitrate = flag("bitrate").flatMap { Int($0) }
    guard args.count >= 2 else { fail("encode requires <in> <out>") }
    let input = args[0], output = args[1]

    let inFile = openForReading(input)
    let sampleRate = inFile.processingFormat.sampleRate
    let channels = Int(inFile.processingFormat.channelCount)
    let originalLength = inFile.length

    switch api {
    case "avaudiofile":
        var settings: [String: Any] = [
            AVFormatIDKey: codec == "alac" ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if codec == "aac", let bitrate {
            settings[AVEncoderBitRateKey] = bitrate
            settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
        }
        if codec == "alac" {
            settings[AVEncoderBitDepthHintKey] = 16
        }
        encodeViaAVAudioFile(input: input, output: output, settings: settings)

    case "extaudiofile":
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: codec == "alac" ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: codec == "alac" ? 4096 : 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0
        )
        encodeViaExtAudioFile(input: input, output: output,
                              fileType: kAudioFileM4AType, outputASBD: &asbd, bitrate: bitrate)

    default:
        fail("unknown --api \(api)")
    }

    // Round-trip check: what does AVAudioFile report for the encoded file?
    guard let roundTrip = try? AVAudioFile(forReading: URL(fileURLWithPath: output)) else {
        fail("encoded file is unreadable: \(output)")
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? Int) ?? nil
    emit([
        "api": api, "codec": codec, "bitrate": bitrate ?? -1,
        "in": input, "out": output,
        "originalLength": originalLength,
        "roundTripLength": roundTrip.length,
        "lengthDelta": roundTrip.length - originalLength,
        "exactLength": roundTrip.length == originalLength,
        "outSizeBytes": size ?? -1,
        "roundTripFormat": formatDescription(roundTrip.fileFormat),
    ])
}

// ─── beeps (seek fixture) ────────────────────────────────────────────────────

func runBeeps() {
    guard let path = args.first else { fail("beeps requires <out.wav>") }
    let minutes = Double(flag("minutes") ?? "10") ?? 10
    let period = Double(flag("period") ?? "30") ?? 30
    let sampleRate = 16000.0
    let totalFrames = Int(minutes * 60 * sampleRate)
    let beepFrames = Int(0.040 * sampleRate)   // 40 ms tone
    let rampFrames = 8                         // ~0.5 ms ramp: sharp but not clicky

    var samples = [Float](repeating: 0, count: totalFrames)
    // Low-level noise floor so silence-detection paths behave like real audio.
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for i in 0..<totalFrames {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let r = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
        samples[i] = r * 0.0008
    }

    var beepTimes = [Double]()
    var t = period
    while t < minutes * 60 - 1 {
        beepTimes.append(t)
        t += period
    }
    // Also probe the very start and a point near the end.
    beepTimes.insert(1.0, at: 0)
    beepTimes.append(minutes * 60 - 2.0)

    for time in beepTimes {
        let start = Int(time * sampleRate)
        for k in 0..<beepFrames {
            guard start + k < totalFrames else { break }
            let envelope: Float
            if k < rampFrames { envelope = Float(k) / Float(rampFrames) }
            else if k > beepFrames - rampFrames { envelope = Float(beepFrames - k) / Float(rampFrames) }
            else { envelope = 1.0 }
            let phase = 2.0 * Double.pi * 1000.0 * Double(k) / sampleRate
            samples[start + k] += 0.65 * envelope * Float(sin(phase))
        }
    }

    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                              channels: 1, interleaved: false)!
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    guard let outFile = try? AVAudioFile(forWriting: url, settings: settings) else {
        fail("cannot create \(path)")
    }
    let chunk = 1 << 16
    var offset = 0
    while offset < totalFrames {
        let n = min(chunk, totalFrames - offset)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
            fail("buffer alloc failed")
        }
        buffer.frameLength = AVAudioFrameCount(n)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: n)
        }
        do { try outFile.write(from: buffer) } catch { fail("write failed: \(error)") }
        offset += n
    }
    emit(["path": path, "frames": totalFrames, "sampleRate": sampleRate,
          "beepTimes": beepTimes, "beepDurationMs": 40.0])
}

// ─── seek ────────────────────────────────────────────────────────────────────

/// Read a decoded PCM window [start, start+duration) using AVAssetReader with a
/// timeRange — the same precise-timing machinery AVPlayer seeks with.
func readWindow(url: URL, start: Double, duration: Double) -> (samples: [Float], sampleRate: Double)? {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
    guard let reader = try? AVAssetReader(asset: asset) else { return nil }
    let timescale: CMTimeScale = 16000
    reader.timeRange = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: timescale),
        duration: CMTime(seconds: duration, preferredTimescale: timescale)
    )
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    guard reader.startReading() else { return nil }

    var samples = [Float]()
    while let sampleBuffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
        bytes.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            samples.append(contentsOf: floats)
        }
    }
    if reader.status == .failed { return nil }
    return (samples, 16000)
}

/// Detect the onset of a 1 kHz burst: first sample index where a short
/// rectified moving average crosses a threshold well above the noise floor.
func detectOnset(_ samples: [Float], sampleRate: Double) -> Int? {
    guard samples.count > 64 else { return nil }
    let window = 32
    var running: Float = 0
    for i in 0..<window { running += abs(samples[i]) }
    let threshold: Float = 0.08 * Float(window)
    if running > threshold { return 0 }
    for i in window..<samples.count {
        running += abs(samples[i]) - abs(samples[i - window])
        if running > threshold { return i - window + 1 }
    }
    return nil
}

func runSeek() {
    guard let path = args.first else { fail("seek requires <file>") }
    guard let timesArg = flag("times") else { fail("seek requires --times t1,t2,...") }
    let times = timesArg.split(separator: ",").compactMap { Double($0) }
    let lead = 0.250  // seek this far before the beep, so onset lands mid-window
    let url = URL(fileURLWithPath: path)

    var results = [[String: Any]]()
    var worst = 0.0
    var failures = 0
    for time in times {
        let start = max(0, time - lead)
        guard let (samples, sampleRate) = readWindow(url: url, start: start, duration: 1.0) else {
            results.append(["expectedSeconds": time, "error": "read failed"])
            failures += 1
            continue
        }
        guard let onset = detectOnset(samples, sampleRate: sampleRate) else {
            results.append(["expectedSeconds": time, "error": "no onset detected",
                            "framesRead": samples.count])
            failures += 1
            continue
        }
        let observed = start + Double(onset) / sampleRate
        let errorMs = (observed - time) * 1000.0
        worst = max(worst, abs(errorMs))
        results.append([
            "expectedSeconds": time,
            "observedSeconds": observed,
            "errorMs": errorMs,
            "framesRead": samples.count,
        ])
    }
    emit(["path": path, "points": results, "worstAbsErrorMs": worst, "failures": failures])
}

// ─── Dispatch ────────────────────────────────────────────────────────────────

switch subcommand {
case "info":   runInfo()
case "dump":   runDump()
case "encode": runEncode()
case "beeps":  runBeeps()
case "seek":   runSeek()
default:       fail("unknown subcommand \(subcommand)")
}
