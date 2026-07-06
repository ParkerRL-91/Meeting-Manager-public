import Foundation

/// Pure, testable word-level speaker alignment (whisperX-style). Splits a
/// Whisper segment into per-speaker sub-rows using word timings, so a single
/// transcribed segment that spans a speaker change is no longer credited
/// wholesale to whoever spoke at its start. Falls back to whole-segment
/// best-overlap (the `alignToTranscripts` rule) when word timings are
/// unavailable — Apple Speech, or WhisperKit returning none.
///
/// No actors, no I/O — mirrors `SpeakerNamingEngine`. Constants are exposed so
/// tests can pin thresholds directly. `align` never returns an empty array for
/// a segment with non-empty text: the degenerate answer is one full-span row
/// with `sid == nil` (the caller renders that as the generic "Speaker").
enum TranscriptAligner {

    /// One diarization turn. `sid` is the 1-based cluster number the caller has
    /// already normalized (both engines emit 1-based ids by the time they reach
    /// `batchTranscribe`). Times share the segment's timebase (trimmed-audio-
    /// relative seconds), which is also the diarization timebase.
    struct Turn: Sendable, Equatable {
        let sid: Int
        let start: Double
        let end: Double
    }

    /// One aligned sub-row of a transcript segment. The sub-rows for a segment
    /// are contiguous and non-overlapping and exactly tile
    /// `[segment.startTime, segment.endTime]`. `sid == nil` means "no confident
    /// speaker" — the caller labels it the generic "Speaker".
    struct AlignedRow: Sendable, Equatable {
        let text: String
        let startTime: Double
        let endTime: Double
        let sid: Int?
    }

    /// Fallback-path threshold — identical to `alignToTranscripts` (the winning
    /// turn must overlap ≥25% of the interval length).
    static let minimumOverlapRatio: Double = 0.25

    /// Word groups with this many words or fewer are treated as boundary jitter
    /// and merged into the temporally nearer neighbor group. A one-word split is
    /// overwhelmingly DTW boundary noise and is useless to vocative mining / LLM
    /// attribution; genuine two-word backchannels ("yeah, exactly") survive.
    static let maxFragmentWords: Int = 1

    /// Minimum spacing enforced between consecutive sub-row boundaries so rows
    /// can never collide on the `(meetingId, startTime, endTime)` unique index.
    static let boundaryEpsilon: Double = 0.01

    /// Split `segment` into per-speaker sub-rows against `turns`.
    static func align(segment: TranscriptSegment, turns: [Turn]) -> [AlignedRow] {
        let full = AlignedRow(
            text: segment.text,
            startTime: segment.startTime,
            endTime: segment.endTime,
            sid: nil
        )

        // No diarization at all → one anonymous row.
        guard !turns.isEmpty else { return [full] }

        // Fallback path: no word timings → whole-segment best-overlap.
        func fallback() -> [AlignedRow] {
            let sid = bestOverlapSid(start: segment.startTime, end: segment.endTime, turns: turns)
            return [AlignedRow(text: segment.text, startTime: segment.startTime, endTime: segment.endTime, sid: sid)]
        }
        guard let rawWords = segment.words, !rawWords.isEmpty else { return fallback() }

        // Sanitize: clamp word times into the segment span (DTW occasionally
        // drifts slightly out of range) and enforce end >= start.
        let words: [WordStamp] = rawWords.map { w in
            let s = min(max(w.start, segment.startTime), segment.endTime)
            let e = min(max(max(w.end, s), segment.startTime), segment.endTime)
            return WordStamp(text: w.text, start: s, end: e)
        }
        guard !words.isEmpty else { return fallback() }

        // Assign each word to the turn covering its midpoint.
        var sids: [Int?] = words.map { assignWord($0, turns: turns) }

        // No word landed in any turn → treat like the word-less case so we get
        // the proven ≥25% best-overlap verdict rather than trusting bad data.
        guard sids.contains(where: { $0 != nil }) else { return fallback() }

        fillUnassignedRuns(words: words, sids: &sids)

        // Coalesce consecutive same-sid words into groups, then merge fragments.
        var groups = coalesce(words: words, sids: sids)
        mergeFragments(&groups)

        // Single group → one row spanning the segment (keep original text).
        if groups.count == 1 {
            return [AlignedRow(text: segment.text, startTime: segment.startTime, endTime: segment.endTime, sid: groups[0].sid)]
        }

        // Emit rows tiling [segment.startTime, segment.endTime] with strictly
        // increasing boundaries (epsilon-spaced so the unique index is safe).
        var rows: [AlignedRow] = []
        var lo = segment.startTime
        let n = groups.count
        for i in 0..<n {
            let startTime = (i == 0) ? segment.startTime : lo
            let endTime: Double
            if i == n - 1 {
                endTime = segment.endTime
            } else {
                let raw = (groups[i].words.last!.end + groups[i + 1].words.first!.start) / 2
                // Reserve epsilon room for every remaining boundary plus the end.
                let maxB = segment.endTime - boundaryEpsilon * Double(n - 1 - i)
                var b = min(max(raw, lo + boundaryEpsilon), maxB)
                if b <= lo { b = lo + boundaryEpsilon }   // extreme-degenerate guard; DB OR IGNORE backstops
                endTime = b
                lo = b
            }
            let text = groups[i].words.map(\.text).joined(separator: " ")
            rows.append(AlignedRow(text: text, startTime: startTime, endTime: endTime, sid: groups[i].sid))
        }
        return rows
    }

    /// Whole-interval best-overlap (port of `alignToTranscripts`). Returns the
    /// sid of the turn with the greatest overlap with `[start, end]` iff that
    /// overlap is ≥ `minimumOverlapRatio` of the interval length; `nil`
    /// otherwise (including zero/negative-length intervals and empty turns).
    static func bestOverlapSid(start: Double, end: Double, turns: [Turn]) -> Int? {
        let len = end - start
        guard len > 0 else { return nil }
        var bestSid: Int? = nil
        var bestOverlap: Double = 0
        for t in turns {
            let overlap = max(0, min(end, t.end) - max(start, t.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSid = t.sid
            }
        }
        guard bestOverlap / len >= minimumOverlapRatio else { return nil }
        return bestSid
    }

    // MARK: - Private

    private struct Group {
        var words: [WordStamp]
        let sid: Int
    }

    /// Pick the turn covering the word's midpoint; among overlapping turns
    /// (engines can emit overlaps) prefer greater overlap of the word interval,
    /// then earlier turn start, then smaller sid. `nil` if no turn covers it.
    private static func assignWord(_ w: WordStamp, turns: [Turn]) -> Int? {
        let mid = (w.start + w.end) / 2
        let wEnd = max(w.end, w.start + boundaryEpsilon)   // widen so zero-length words have defined overlap
        var best: (sid: Int, overlap: Double, start: Double)? = nil
        for t in turns where t.start <= mid && mid < t.end {
            let overlap = max(0, min(wEnd, t.end) - max(w.start, t.start))
            if let b = best {
                let better = overlap > b.overlap
                    || (overlap == b.overlap && t.start < b.start)
                    || (overlap == b.overlap && t.start == b.start && t.sid < b.sid)
                if better { best = (t.sid, overlap, t.start) }
            } else {
                best = (t.sid, overlap, t.start)
            }
        }
        return best?.sid
    }

    /// Fill runs of unassigned words from their flanking assigned words.
    /// Precondition: at least one word is assigned, so no run spans the whole
    /// array (every run has an assigned neighbor on at least one side).
    private static func fillUnassignedRuns(words: [WordStamp], sids: inout [Int?]) {
        let n = sids.count
        var i = 0
        while i < n {
            guard sids[i] == nil else { i += 1; continue }
            var j = i
            while j + 1 < n && sids[j + 1] == nil { j += 1 }   // run [i...j]
            let leftSid = i > 0 ? sids[i - 1] : nil
            let rightSid = j + 1 < n ? sids[j + 1] : nil
            switch (leftSid, rightSid) {
            case let (l?, r?) where l == r:
                for k in i...j { sids[k] = l }
            case let (l?, r?):
                // Different flanks — each word takes the temporally nearer flank
                // (by the flanking words' midpoints).
                let leftAnchor = (words[i - 1].start + words[i - 1].end) / 2
                let rightAnchor = (words[j + 1].start + words[j + 1].end) / 2
                for k in i...j {
                    let m = (words[k].start + words[k].end) / 2
                    sids[k] = abs(m - leftAnchor) <= abs(rightAnchor - m) ? l : r
                }
            case let (l?, nil):
                for k in i...j { sids[k] = l }
            case let (nil, r?):
                for k in i...j { sids[k] = r }
            case (nil, nil):
                break   // unreachable given the precondition
            }
            i = j + 1
        }
    }

    /// Coalesce consecutive same-sid words into groups. All sids are non-nil
    /// after `fillUnassignedRuns`.
    private static func coalesce(words: [WordStamp], sids: [Int?]) -> [Group] {
        var groups: [Group] = []
        for (idx, w) in words.enumerated() {
            let sid = sids[idx] ?? -1
            if var last = groups.last, last.sid == sid {
                last.words.append(w)
                groups[groups.count - 1] = last
            } else {
                groups.append(Group(words: [w], sid: sid))
            }
        }
        return groups
    }

    /// Repeatedly merge fragment groups (≤ `maxFragmentWords` words) into the
    /// temporally nearer neighbor until every group is large enough or only one
    /// remains. Terminates: each merge strictly reduces the group count.
    private static func mergeFragments(_ groups: inout [Group]) {
        while groups.count > 1, let fi = groups.firstIndex(where: { $0.words.count <= maxFragmentWords }) {
            let target: Int
            if fi == 0 {
                target = 1
            } else if fi == groups.count - 1 {
                target = fi - 1
            } else {
                let gapLeft = groups[fi].words.first!.start - groups[fi - 1].words.last!.end
                let gapRight = groups[fi + 1].words.first!.start - groups[fi].words.last!.end
                if gapLeft < gapRight {
                    target = fi - 1
                } else if gapRight < gapLeft {
                    target = fi + 1
                } else {
                    // Tie → more words, then the earlier (left) neighbor.
                    target = groups[fi + 1].words.count > groups[fi - 1].words.count ? fi + 1 : fi - 1
                }
            }
            let targetSid = groups[target].sid
            // Rebuild with the fragment's words reassigned to the target sid,
            // then re-coalesce so adjacent same-sid groups merge.
            var flatWords: [WordStamp] = []
            var flatSids: [Int] = []
            for (gi, g) in groups.enumerated() {
                let sid = (gi == fi) ? targetSid : g.sid
                for w in g.words { flatWords.append(w); flatSids.append(sid) }
            }
            groups = coalesce(words: flatWords, sids: flatSids.map { Optional($0) })
        }
    }
}
