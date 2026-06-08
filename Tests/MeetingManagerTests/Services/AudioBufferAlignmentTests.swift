import AVFoundation
import XCTest
@testable import MeetingManager

// Verifies the capture fix: the persisted mixed and system WAVs share ONE
// timeline. System audio arrives sparsely (only while remote audio plays) and
// the system tap starts BEFORE the mic, so the timeline must anchor to the mic
// and silence-pad system to its real wall-clock position. These drive the real
// AudioBufferManager with synthetic buffers at controlled host times — the only
// way to check alignment without recording a meeting. (XCTest runs in CI; the
// dev machine has no Xcode.)
final class AudioBufferAlignmentTests: XCTestCase {

    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private func constBuffer(_ value: Float, frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        let ch = b.floatChannelData![0]
        for i in 0..<frames { ch[i] = value }
        return b
    }

    private func rampBuffer(frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        let ch = b.floatChannelData![0]
        for i in 0..<frames { ch[i] = Float(i) / Float(frames) }
        return b
    }

    // seconds → mach host-time units (inverse of AudioBufferManager.hostSeconds)
    private func host(_ base: UInt64, plus seconds: Double) -> UInt64 {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let units = seconds * 1_000_000_000 * Double(tb.denom) / Double(tb.numer)
        return base &+ UInt64(units)
    }

    private func tmpURL(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(tag)-\(UInt64(bitPattern: Int64(Int32.random(in: .min ... .max)))).wav")
    }

    private func read(_ url: URL) -> [Float] {
        // AVAudioFile.read returns SHORT reads (it stops at internal packet
        // boundaries), so a single read yields fewer than `length` frames. Loop,
        // bounding each read by the frames remaining, until EOF.
        guard let f = try? AVAudioFile(forReading: url) else { return [] }
        let block: AVAudioFrameCount = 32768
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: block) else { return [] }
        var out: [Float] = []
        while f.framePosition < f.length {
            let want = min(block, AVAudioFrameCount(f.length - f.framePosition))
            b.frameLength = 0
            do { try f.read(into: b, frameCount: want) } catch { break }
            let n = Int(b.frameLength)
            if n == 0 { break }
            if let ch = b.floatChannelData { out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n)) }
        }
        return out
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: AudioBufferManager.systemAudioURL(for: url))
    }

    // MARK: - Production ordering: system tap fires FIRST (BUG-1 regression guard)

    func testSystemFirstStillAlignsToMic() throws {
        let mgr = AudioBufferManager()
        let url = tmpURL("sysfirst"); defer { cleanup(url) }
        try mgr.prepareForRecording(outputURL: url)
        let t0 = mach_absolute_time()
        let half = 8000

        // System buffer arrives BEFORE any mic buffer (the real start ordering).
        mgr.appendSystemBuffer(constBuffer(0.3, frames: half), at: AVAudioTime(hostTime: t0))
        // Mic: continuous 1.5s, its first buffer defines t0.
        mgr.appendMicBuffer(constBuffer(0.5, frames: half), at: AVAudioTime(hostTime: t0))
        mgr.appendMicBuffer(constBuffer(0.5, frames: half), at: AVAudioTime(hostTime: host(t0, plus: 0.5)))
        mgr.appendMicBuffer(constBuffer(0.5, frames: half), at: AVAudioTime(hostTime: host(t0, plus: 1.0)))
        mgr.finishRecording()

        let mixed = read(url)
        XCTAssertEqual(Double(mixed.count), 24000, accuracy: 800, "mixed should span the full mic timeline")
        // System overlapped the first 0.5s → mic+system; the rest is mic-only.
        XCTAssertEqual(mixed[3200], 0.40, accuracy: 0.02, "first 0.5s should be mic(0.5)+system(0.3) mixed")
        XCTAssertEqual(mixed[20000], 0.25, accuracy: 0.02, "after 0.5s should be mic-only")
    }

    // MARK: - System silent at start → silence-padded to wall-clock

    func testSystemSilentAtStartIsSilencePadded() throws {
        let mgr = AudioBufferManager()
        let url = tmpURL("silentstart"); defer { cleanup(url) }
        try mgr.prepareForRecording(outputURL: url)
        let t0 = mach_absolute_time()
        let half = 8000

        mgr.appendMicBuffer(constBuffer(0.5, frames: half), at: AVAudioTime(hostTime: t0))
        mgr.appendMicBuffer(constBuffer(0.5, frames: half), at: AVAudioTime(hostTime: host(t0, plus: 0.5)))
        mgr.appendMicBuffer(constBuffer(0.5, frames: half), at: AVAudioTime(hostTime: host(t0, plus: 1.0)))
        // System only plays in the last 0.5s.
        mgr.appendSystemBuffer(constBuffer(0.3, frames: half), at: AVAudioTime(hostTime: host(t0, plus: 1.0)))
        mgr.finishRecording()

        let system = read(AudioBufferManager.systemAudioURL(for: url))
        let mixed = read(url)
        XCTAssertEqual(Double(system.count), 24000, accuracy: 800, "system must be silence-padded to full length")
        XCTAssertLessThan(abs(system[3200]), 0.01, "system silent at 0.2s")
        XCTAssertEqual(system[20000], 0.3, accuracy: 0.02, "system carries 0.3 at 1.25s")
        XCTAssertEqual(mixed[3200], 0.25, accuracy: 0.02, "mixed mic-only early")
        XCTAssertEqual(mixed[20000], 0.40, accuracy: 0.02, "mixed mic+system late")
    }

    // MARK: - Ramp alignment (catches sub-50ms shifts a DC signal would hide)

    func testRampAlignmentIsExact() throws {
        let mgr = AudioBufferManager()
        let url = tmpURL("ramp"); defer { cleanup(url) }
        try mgr.prepareForRecording(outputURL: url)
        let frames = 16000
        mgr.appendMicBuffer(rampBuffer(frames: frames), at: AVAudioTime(hostTime: mach_absolute_time()))
        mgr.finishRecording()

        let mixed = read(url)
        XCTAssertEqual(mixed.count, frames, "no leading/trailing shift")
        // mixed[i] == (i/frames) * 0.5 — any timeline shift breaks this at every i.
        for k in [10, 4000, 8000, 12000, 15990] {
            XCTAssertEqual(mixed[k], (Float(k) / Float(frames)) * 0.5, accuracy: 1e-3, "ramp misaligned at \(k)")
        }
    }

    // MARK: - Distinct-value mix (fails on mic-only / system-only / concat)

    func testDistinctValuesAreTrulyMixed() throws {
        let mgr = AudioBufferManager()
        let url = tmpURL("distinct"); defer { cleanup(url) }
        try mgr.prepareForRecording(outputURL: url)
        let t0 = mach_absolute_time()
        let twoSec = 32000
        mgr.appendMicBuffer(constBuffer(0.4, frames: twoSec), at: AVAudioTime(hostTime: t0))
        mgr.appendSystemBuffer(constBuffer(0.2, frames: twoSec), at: AVAudioTime(hostTime: t0))
        mgr.finishRecording()

        let mixed = read(url)
        XCTAssertEqual(Double(mixed.count), 32000, accuracy: 1600)
        // (0.4 + 0.2) * 0.5 = 0.30. mic-only=0.20, system-only=0.10, concat≈len 64000.
        for k in [100, 16000, 31000] {
            XCTAssertEqual(mixed[k], 0.30, accuracy: 0.005, "should be a true mix at \(k), not one stream")
        }
    }

    // MARK: - Multi-block merge (catches short-read desync, BUG-4)

    func testMultiBlockMergeDoesNotDesync() throws {
        let mgr = AudioBufferManager()
        let url = tmpURL("multiblock"); defer { cleanup(url) }
        try mgr.prepareForRecording(outputURL: url)
        let t0 = mach_absolute_time()
        // Distinct values + UNEQUAL, non-block-multiple lengths (system shorter,
        // boundary at 70001 ≠ k*32000) to exercise the partial-block + unequal-tail
        // refill path, not just block-aligned EOF.
        let micN = 100000, sysN = 70001  // ~3 blocks; system tail boundary mid-block
        mgr.appendMicBuffer(constBuffer(0.4, frames: micN), at: AVAudioTime(hostTime: t0))
        mgr.appendSystemBuffer(constBuffer(0.2, frames: sysN), at: AVAudioTime(hostTime: t0))
        mgr.finishRecording()

        let mixed = read(url)
        XCTAssertEqual(Double(mixed.count), Double(micN), accuracy: 2000, "mixed length tracks the longer (mic) stream")
        // Overlap region = (0.4+0.2)*0.5 = 0.30; mic-only tail = (0.4)*0.5 = 0.20.
        // A desync would smear the 0.30→0.20 boundary or zero late frames.
        for k in [100, 35000, 69000] {
            XCTAssertEqual(mixed[k], 0.30, accuracy: 0.01, "overlap region should be a true mix at \(k)")
        }
        for k in [72000, 99000] {
            XCTAssertEqual(mixed[k], 0.20, accuracy: 0.01, "mic-only tail after system EOF at \(k)")
        }
    }

    // MARK: - Empty recording + double finish (no crash, valid file)

    func testEmptyRecordingProducesValidFileAndDoubleFinishIsSafe() throws {
        let mgr = AudioBufferManager()
        let url = tmpURL("empty"); defer { cleanup(url) }
        try mgr.prepareForRecording(outputURL: url)
        mgr.finishRecording()
        mgr.finishRecording()  // must not crash / throw
        XCTAssertNotNil(try? AVAudioFile(forReading: url), "empty recording should still be a valid WAV")
    }

    // MARK: - Reuse across recordings resets the timeline (H8)

    func testManagerReuseResetsTimeline() throws {
        let mgr = AudioBufferManager()
        let url1 = tmpURL("reuse1"); defer { cleanup(url1) }
        try mgr.prepareForRecording(outputURL: url1)
        mgr.appendMicBuffer(constBuffer(0.5, frames: 16000), at: AVAudioTime(hostTime: mach_absolute_time()))
        mgr.finishRecording()

        let url2 = tmpURL("reuse2"); defer { cleanup(url2) }
        try mgr.prepareForRecording(outputURL: url2)
        mgr.appendMicBuffer(constBuffer(0.2, frames: 16000), at: AVAudioTime(hostTime: mach_absolute_time()))
        mgr.finishRecording()

        let mixed2 = read(url2)
        XCTAssertEqual(Double(mixed2.count), 16000, accuracy: 800, "recording #2 must be ~1s, not inherit #1's timeline")
        XCTAssertEqual(mixed2[8000], 0.10, accuracy: 0.02, "recording #2 amplitude is its own (0.2*0.5)")
    }

    // MARK: - Moderate system gap silence-pads without runaway

    func testModerateGapSilencePads() throws {
        let mgr = AudioBufferManager()
        let url = tmpURL("gap"); defer { cleanup(url) }
        try mgr.prepareForRecording(outputURL: url)
        let t0 = mach_absolute_time()
        mgr.appendMicBuffer(constBuffer(0.5, frames: 16000), at: AVAudioTime(hostTime: t0))
        mgr.appendMicBuffer(constBuffer(0.5, frames: 48000), at: AVAudioTime(hostTime: host(t0, plus: 1.0)))  // mic to 4s
        // System first plays at 3s.
        mgr.appendSystemBuffer(constBuffer(0.3, frames: 16000), at: AVAudioTime(hostTime: host(t0, plus: 3.0)))
        mgr.finishRecording()

        let system = read(AudioBufferManager.systemAudioURL(for: url))
        XCTAssertEqual(Double(system.count), 64000, accuracy: 1600, "system padded from 0 to its 3–4s window")
        XCTAssertLessThan(abs(system[16000]), 0.01, "silent at 1s")
        XCTAssertEqual(system[56000], 0.3, accuracy: 0.02, "0.3 at 3.5s")
    }

    // MARK: - Mic gap from a mid-recording switch silence-pads the mixed timeline (ADR-012)

    // ADR-012 (dynamic mic switching) leans on writePositioned to keep one
    // timeline across a switch: switchDevice does a stop()/start() that halts mic
    // buffers for the swap, then they resume. Because t0 is anchored on the FIRST
    // mic buffer and forward gaps are silence-padded, the resumed audio must land
    // at its true wall-clock offset (~5s here), not be spliced right after the
    // pre-switch audio. This is the mic-stream analog of testModerateGapSilencePads.
    func testMicGapFromSwitchIsSilencePadded() throws {
        let mgr = AudioBufferManager()
        let url = tmpURL("micgap"); defer { cleanup(url) }
        try mgr.prepareForRecording(outputURL: url)
        let t0 = mach_absolute_time()
        let pre = 4000     // 0.25s of mic before the switch
        let post = 4000    // 0.25s of mic after resuming
        let gapSeconds = 5.0
        let resumeOffset = Int(gapSeconds * 16000)  // 80000 — where the resume buffer must land

        // First mic buffer anchors the shared timeline at t0.
        mgr.appendMicBuffer(constBuffer(0.5, frames: pre), at: AVAudioTime(hostTime: t0))
        // Mic buffers stop for ~5s (the engine swap), then resume.
        mgr.appendMicBuffer(constBuffer(0.3, frames: post), at: AVAudioTime(hostTime: host(t0, plus: gapSeconds)))
        mgr.finishRecording()

        let mixed = read(url)
        // ~5s*16000 of silence-padded gap + the 0.25s resume buffer. A splice (the
        // bug this guards) would be only pre+post = 8000 frames (~0.5s) total.
        XCTAssertEqual(Double(mixed.count), Double(resumeOffset + post), accuracy: 1600,
                       "mic gap must be silence-padded to wall-clock (~5s), not spliced to ~0.5s")
        // Pre-switch mic audio present near t=0 (mic 0.5 → 0.25; the empty-system merge halves it).
        XCTAssertEqual(mixed[pre / 2], 0.25, accuracy: 0.02, "pre-switch mic audio present near t=0")
        // The entire gap is interpolated silence (not pre/post audio shifted into it).
        XCTAssertLessThan(abs(mixed[8000]), 0.01, "silence just after the pre-switch buffer")
        XCTAssertLessThan(abs(mixed[40000]), 0.01, "silence in the middle of the gap")
        XCTAssertLessThan(abs(mixed[72000]), 0.01, "silence just before the resume")
        // Resumed mic audio present at its true ~5s offset (mic 0.3 → 0.15).
        XCTAssertEqual(mixed[resumeOffset + post / 2], 0.15, accuracy: 0.02, "resumed mic audio at t≈5s")
    }

    // MARK: - Invalid host time does not crash and stays bounded (BUG-2)

    func testInvalidHostTimeIsHandled() throws {
        let mgr = AudioBufferManager()
        let url = tmpURL("invalidhost"); defer { cleanup(url) }
        try mgr.prepareForRecording(outputURL: url)
        // sampleTime-based AVAudioTime has no valid host time → fallback path.
        mgr.appendMicBuffer(constBuffer(0.5, frames: 16000), at: AVAudioTime(sampleTime: 0, atRate: 16000))
        mgr.appendMicBuffer(constBuffer(0.5, frames: 16000), at: AVAudioTime(hostTime: mach_absolute_time()))
        mgr.finishRecording()
        let mixed = read(url)
        XCTAssertGreaterThan(mixed.count, 0, "should still produce audio, no crash")
        XCTAssertLessThan(mixed.count, 16000 * 60, "length stays bounded")
    }
}
