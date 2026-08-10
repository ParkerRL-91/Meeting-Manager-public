import Foundation

/// The one place that knows how a recorded `.wav` is laid out on disk.
///
/// Crash-husk repair and husk classification both need to know where the audio
/// payload starts, and both used to hardcode it. `AVAudioFile` pads its header
/// with a `FLLR` chunk so the `data` payload begins at 4096 for BOTH the Int16
/// and Float32 settings we write — but that padding is an undocumented
/// implementation detail, and a fixed offset silently turns header repair into a
/// no-op (and the size threshold into a misclassifier) the moment it changes.
/// Walking the RIFF chunk list instead works for any layout, including files
/// written by an older build.
enum WavFileLayout {

    /// Where a located `data` chunk lives, and what its header claims.
    struct DataChunk {
        /// Offset of the 4-byte little-endian size field.
        let sizeFieldOffset: UInt64
        /// Offset of the first audio byte.
        let payloadOffset: UInt64
        /// Size the header declares — 0 on a file killed before `AVAudioFile.close`.
        let declaredSize: UInt32
    }

    /// Locate the `data` chunk by walking the chunk list from offset 12.
    /// Returns nil when the file isn't RIFF/WAVE, is truncated mid-header, or
    /// declares a chunk that runs off the end — callers must read nil as
    /// "don't touch this file".
    static func findDataChunk(in handle: FileHandle, fileSize: UInt64) throws -> DataChunk? {
        guard fileSize >= 12 else { return nil }
        try handle.seek(toOffset: 0)
        guard let riff = try handle.read(upToCount: 12), riff.count == 12,
              riff.prefix(4) == Data("RIFF".utf8),
              riff.suffix(4) == Data("WAVE".utf8) else { return nil }

        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { return nil }
            let size = header.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            }
            if header.prefix(4) == Data("data".utf8) {
                return DataChunk(sizeFieldOffset: offset + 4, payloadOffset: offset + 8, declaredSize: size)
            }
            // RIFF chunks are word-aligned: an odd payload carries one pad byte.
            offset += 8 + UInt64(size) + UInt64(size % 2)
        }
        return nil
    }

    /// Convenience wrapper for read-only callers.
    static func findDataChunk(atPath path: String) -> DataChunk? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        return try? findDataChunk(in: handle, fileSize: size)
    }

    /// True when the `.wav` at `path` physically holds at least one audio byte.
    /// Keyed on bytes PRESENT past the payload offset, not on the size the
    /// header declares: a recording killed before `AVAudioFile.close` declares
    /// size 0 while holding hours of real audio, and
    /// `TaskQueueManager.repairWavHeaderIfNeeded` exists to recover exactly
    /// that — so it must never be classified as an empty husk.
    static func containsAudioBytes(atPath path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(),
              let chunk = try? findDataChunk(in: handle, fileSize: fileSize) else { return false }
        return fileSize > chunk.payloadOffset
    }
}
