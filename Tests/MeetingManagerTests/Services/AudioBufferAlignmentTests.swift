import AVFoundation
import XCTest
@testable import MeetingManager

// Verifies the capture fix: the persisted mixed and system WAVs share ONE
// timeline. System audio arrives sparsely (only while remote audio plays), so
// it must be silence-padded to its real wall-clock position — not concatenated.
// These drive the real AudioBufferManager with synthetic buffers at controlled
// host times (the only way to check alignment without recording a meeting).
final class AudioBufferAlignmentTests: XCTestCase {

    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private func buffer(value: Float, frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        let ch = b.floatChannelData![0]
        for i in 0..<frames { ch[i] = value }
        return b
    }

    // seconds → mach host-time units (inverse of AudioBufferManager.hostSeconds)
    private func host(_ base: UInt64, plus seconds: Double) -> UInt64 {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let units = seconds * 1_000_000_000 * Double(tb.denom) / Double(tb.numer)
        return base &+ UInt64(units)
    }

    private func read(_ url: URL) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url),
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
        try? f.read(into: b)
        guard let ch = b.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(b.frameLength)))
    }

    func testMixedAndSystemShareOneTimeline() throws {
        let mgr = AudioBufferManager()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let mixedURL = dir.appendingPathComponent("align-test-\(UInt64(abs(Int32.random(in: .min ... .max)))).wav")
        let systemURL = AudioBufferManager.systemAudioURL(for: mixedURL)
        defer { try? FileManager.default.removeItem(at: mixedURL); try? FileManager.default.removeItem(at: systemURL) }

        try mgr.prepareForRecording(outputURL: mixedURL)

        let t0 = mach_absolute_time()
        let half = 8000  // 0.5s at 16 kHz

        // Mic: continuous for 1.5s (three 0.5s buffers at 0.0, 0.5, 1.0).
        mgr.appendMicBuffer(buffer(value: 0.5, frames: half), at: AVAudioTime(hostTime: t0))
        mgr.appendMicBuffer(buffer(value: 0.5, frames: half), at: AVAudioTime(hostTime: host(t0, plus: 0.5)))
        mgr.appendMicBuffer(buffer(value: 0.5, frames: half), at: AVAudioTime(hostTime: host(t0, plus: 1.0)))

        // System: ONE 0.5s buffer starting at 1.0s — the first 1.0s is silence.
        mgr.appendSystemBuffer(buffer(value: 0.3, frames: half), at: AVAudioTime(hostTime: host(t0, plus: 1.0)))

        mgr.finishRecording()

        let mixed = read(mixedURL)
        let system = read(systemURL)

        // Both files run the full 1.5s (24000 frames), within a small tolerance.
        XCTAssertEqual(Double(mixed.count), 24000, accuracy: 800, "mixed should span the full timeline, got \(mixed.count)")
        XCTAssertEqual(Double(system.count), 24000, accuracy: 800, "system must be silence-padded to full length, got \(system.count)")

        // System: silent in the first second, signal in the last half second.
        XCTAssertLessThan(abs(system[3200]), 0.01, "system should be silent at 0.2s")
        XCTAssertEqual(system[20000], 0.3, accuracy: 0.02, "system should carry 0.3 at 1.25s")

        // Mixed: mic-only first second (0.5*0.5=0.25), mic+system after (0.4).
        XCTAssertEqual(mixed[3200], 0.25, accuracy: 0.02, "mixed at 0.2s should be mic-only")
        XCTAssertEqual(mixed[20000], 0.40, accuracy: 0.02, "mixed at 1.25s should be mic+system")
    }

    func testMixedIsNotConcatenationOfStreams() throws {
        // The old bug wrote both streams into one file (length ≈ mic+system).
        // With the fix the mixed length tracks the timeline, not the sum.
        let mgr = AudioBufferManager()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let mixedURL = dir.appendingPathComponent("concat-test-\(UInt64(abs(Int32.random(in: .min ... .max)))).wav")
        let systemURL = AudioBufferManager.systemAudioURL(for: mixedURL)
        defer { try? FileManager.default.removeItem(at: mixedURL); try? FileManager.default.removeItem(at: systemURL) }

        try mgr.prepareForRecording(outputURL: mixedURL)
        let t0 = mach_absolute_time()
        let sec = 16000
        // 2s mic + 2s system, fully overlapping in time.
        mgr.appendMicBuffer(buffer(value: 0.5, frames: 2 * sec), at: AVAudioTime(hostTime: t0))
        mgr.appendSystemBuffer(buffer(value: 0.5, frames: 2 * sec), at: AVAudioTime(hostTime: t0))
        mgr.finishRecording()

        let mixed = read(mixedURL)
        // Overlapping → ~2s, NOT ~4s (which the concatenation bug produced).
        XCTAssertEqual(Double(mixed.count), 32000, accuracy: 1600, "overlapping streams should mix to ~2s, not concatenate to 4s")
    }
}
