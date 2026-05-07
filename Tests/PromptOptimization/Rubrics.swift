import Foundation

/// Outcome of scoring one (candidate, fixture) pair.
struct ScoreResult {
    /// 0.0 – 1.0. Primary metric — drives ranking. Higher is better.
    let primary: Double
    /// Named secondary metrics, all in [0, 1]. Used for the promotion gate
    /// ("within 10% of the best on every secondary"). Higher is better.
    let secondary: [String: Double]
    /// Free-form notes the harness prints under each result. Things like
    /// "JSON parse failed" or "hallucinated name: Bob".
    let notes: [String]
    /// Latency in seconds. Not part of the score directly but printed and
    /// stored so the user can see speed vs. quality tradeoffs.
    let elapsedSeconds: Double
}

enum Rubrics {

    // MARK: - Action item

    /// Primary: fraction of expected action items present in the output
    /// (recall). Secondaries: precision, JSON validity, no-hallucination,
    /// assignee accuracy.
    static func scoreActionItem(output: String, fixture: Fixture, elapsed: Double) -> ScoreResult {
        var notes: [String] = []
        let cleaned = stripCodeFence(output)

        // JSON validity — binary
        let jsonValid: Bool
        var parsed: [[String: Any]] = []
        if let data = cleaned.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            jsonValid = true
            parsed = arr
        } else {
            jsonValid = false
            notes.append("JSON parse failed")
        }

        // Recall — % of expected items present in output (substring match
        // on either the action verb phrase or the assignee+key noun).
        let expected = fixture.expectedActionItems
        var matched = 0
        for exp in expected {
            let needle = exp.what.lowercased()
            let outputLower = cleaned.lowercased()
            // Forgiving: any 4+ consecutive word overlap counts as a match.
            // Imperfect but cheap and good enough for ranking candidates.
            let words = needle.split(separator: " ").map(String.init).filter { $0.count > 3 }
            let chunks = stride(from: 0, to: max(0, words.count - 3), by: 1).map { i in
                words[i..<min(i + 4, words.count)].joined(separator: " ")
            }
            if chunks.contains(where: { outputLower.contains($0) }) {
                matched += 1
            }
        }
        let recall = expected.isEmpty ? 1.0 : Double(matched) / Double(expected.count)

        // Precision proxy — assume each parsed item attributed to a real
        // participant + non-empty title is "valid". Hallucinations or
        // empty-title items count against.
        let participantSet = Set(fixture.participants.map { $0.lowercased() })
        var validItems = 0
        var hallucinations = 0
        for item in parsed {
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let assignee = (item["assignee"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if title.isEmpty { continue }
            if assignee.isEmpty {
                validItems += 1
                continue
            }
            // Assignee must be a participant or a name explicitly mentioned
            // in the transcript (e.g. "loop in Mara"). Otherwise hallucination.
            let lowerAssignee = assignee.lowercased()
            let isParticipant = participantSet.contains { lowerAssignee.contains($0) || $0.contains(lowerAssignee) }
            let isMentioned = fixture.namesNotInParticipantsButMentioned
                .contains { lowerAssignee.contains($0.lowercased()) }
            if isParticipant || isMentioned {
                validItems += 1
            } else {
                hallucinations += 1
                notes.append("Hallucinated assignee: \(assignee)")
            }
        }
        let precisionDenom = max(parsed.count, 1)
        let precision = parsed.isEmpty ? (recall == 0 ? 1.0 : 0.0) : Double(validItems) / Double(precisionDenom)
        let noHallucinate = hallucinations == 0 ? 1.0 : 0.0

        // Forbidden-name check
        for forbidden in fixture.forbiddenNames {
            if cleaned.lowercased().contains(forbidden.lowercased()) {
                notes.append("Contains forbidden name: \(forbidden)")
            }
        }

        let primary = recall  // The thing the user cares about most
        return ScoreResult(
            primary: primary,
            secondary: [
                "json_valid":     jsonValid ? 1.0 : 0.0,
                "precision":      precision,
                "no_hallucinate": noHallucinate,
                "item_count_match": expected.isEmpty ? 1.0 : min(1.0, Double(parsed.count) / Double(expected.count)),
            ],
            notes: notes,
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Attribution

    /// Primary: fraction of speaker clusters correctly mapped (or correctly
    /// "Unknown" — under-confidence is acceptable, hallucination is not).
    /// Secondaries: JSON validity, no-hallucination.
    static func scoreAttribution(output: String, fixture: Fixture, elapsed: Double) -> ScoreResult {
        var notes: [String] = []
        let cleaned = stripCodeFence(output)
        let participantSet = Set(fixture.participants.map { $0.lowercased() })

        let parsedDict: [String: String]?
        if let data = cleaned.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsedDict = dict.compactMapValues { $0 as? String }
        } else {
            parsedDict = nil
        }
        let jsonValid = parsedDict != nil
        if !jsonValid { notes.append("JSON parse failed") }

        var hallucinations = 0
        var validValues = 0
        for value in parsedDict?.values ?? Dictionary<String,String>().values {
            let lower = value.lowercased()
            if lower == "unknown" { validValues += 1; continue }
            let isParticipant = participantSet.contains { lower.contains($0) || $0.contains(lower) }
            if isParticipant {
                validValues += 1
            } else {
                hallucinations += 1
                notes.append("Hallucinated attribution: \(value)")
            }
        }
        let total = max(parsedDict?.count ?? 0, 1)
        let primary = Double(validValues) / Double(total)
        let noHallucinate = hallucinations == 0 ? 1.0 : 0.0

        return ScoreResult(
            primary: primary,
            secondary: [
                "json_valid":     jsonValid ? 1.0 : 0.0,
                "no_hallucinate": noHallucinate,
            ],
            notes: notes,
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Summary

    /// Primary: % of expected topics + decisions referenced. Secondaries:
    /// required-section presence, no forbidden names, length-in-band.
    static func scoreSummary(output: String, fixture: Fixture, elapsed: Double) -> ScoreResult {
        var notes: [String] = []
        let lower = output.lowercased()

        // Required sections — at least three of: discussion, decisions,
        // action items, open questions.
        let sectionMarkers = ["discussion", "decision", "action item", "open question"]
        let sectionsPresent = sectionMarkers.filter { lower.contains($0) }.count
        let sectionScore = min(1.0, Double(sectionsPresent) / 3.0)

        // Topic coverage — each expected topic should be referenced.
        let expectedTopics = fixture.expectedTopics
        var topicMatches = 0
        for topic in expectedTopics {
            let topicWords = topic.lowercased().split(separator: " ").filter { $0.count > 3 }
            // Match on any 2+ consecutive significant words from the topic.
            for i in 0..<max(0, topicWords.count - 1) {
                let pair = "\(topicWords[i]) \(topicWords[i+1])"
                if lower.contains(pair) {
                    topicMatches += 1
                    break
                }
            }
        }
        let topicCoverage = expectedTopics.isEmpty ? 1.0 : Double(topicMatches) / Double(expectedTopics.count)

        // Decision coverage — same pattern but for decisions.
        let expectedDecisions = fixture.expectedDecisions
        var decisionMatches = 0
        for decision in expectedDecisions {
            let words = decision.lowercased().split(separator: " ").filter { $0.count > 3 }
            for i in 0..<max(0, words.count - 1) {
                let pair = "\(words[i]) \(words[i+1])"
                if lower.contains(pair) {
                    decisionMatches += 1
                    break
                }
            }
        }
        let decisionCoverage = expectedDecisions.isEmpty ? 1.0 : Double(decisionMatches) / Double(expectedDecisions.count)

        // Forbidden names
        var hallucinations = 0
        for forbidden in fixture.forbiddenNames {
            if lower.contains(forbidden.lowercased()) {
                hallucinations += 1
                notes.append("Forbidden name: \(forbidden)")
            }
        }

        // Length band — 200-1500 words is reasonable for a meeting summary
        let words = output.split(whereSeparator: \.isWhitespace).count
        let lengthOK: Double
        if words < 100      { lengthOK = 0.0; notes.append("Too short (\(words) words)") }
        else if words > 2000 { lengthOK = 0.0; notes.append("Too long (\(words) words)") }
        else                 { lengthOK = 1.0 }

        let primary = (topicCoverage + decisionCoverage) / 2.0
        return ScoreResult(
            primary: primary,
            secondary: [
                "section_presence":    sectionScore,
                "no_hallucinate":      hallucinations == 0 ? 1.0 : 0.0,
                "length_in_band":      lengthOK,
                "topic_coverage":      topicCoverage,
                "decision_coverage":   decisionCoverage,
            ],
            notes: notes,
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Detailed outline

    /// Primary: section count in band (6–12 for ~hour meeting; lower for
    /// short ones — scaled by duration). Secondaries: timestamp coverage of
    /// the transcript (final section reaches transcript end), no-padding
    /// (filler-phrase rate), no-participant-dump (speakers != participants).
    static func scoreOutline(output: String, fixture: Fixture, elapsed: Double) -> ScoreResult {
        var notes: [String] = []
        // Section header pattern: `## [mm:ss – mm:ss]` with various dashes.
        let sectionRegex = try! NSRegularExpression(
            pattern: #"^##\s*\[(\d{1,2}:\d{2})\s*[–\-—]\s*(\d{1,2}:\d{2})\]"#,
            options: [.anchorsMatchLines]
        )
        let nsRange = NSRange(output.startIndex..., in: output)
        let matches = sectionRegex.matches(in: output, range: nsRange)
        let sectionCount = matches.count

        // Target band scales with duration. Roughly 1 section per 5-7 min.
        let durMin = max(1, fixture.durationSeconds / 60)
        let lowBand = max(2, durMin / 7)
        let highBand = max(lowBand, durMin / 4)
        let bandScore: Double
        if sectionCount >= lowBand && sectionCount <= highBand {
            bandScore = 1.0
        } else if sectionCount > highBand {
            bandScore = max(0.0, 1.0 - Double(sectionCount - highBand) / Double(highBand))
            notes.append("Too many sections: \(sectionCount), band \(lowBand)–\(highBand)")
        } else {
            bandScore = max(0.0, Double(sectionCount) / Double(lowBand))
            notes.append("Too few sections: \(sectionCount), band \(lowBand)–\(highBand)")
        }

        // Coverage — does the final section end near the transcript's end?
        // Pull the final timestamp from the transcript (last `_[mm:ss]_` mark).
        let txTsRegex = try! NSRegularExpression(pattern: #"_\[(\d{1,2}:\d{2})\]_"#)
        let txMatches = txTsRegex.matches(in: fixture.transcriptText, range: NSRange(fixture.transcriptText.startIndex..., in: fixture.transcriptText))
        let finalTranscriptTs = txMatches.last
            .flatMap { Range($0.range(at: 1), in: fixture.transcriptText) }
            .map { String(fixture.transcriptText[$0]) } ?? "0:00"
        let finalSectionTs = matches.last
            .flatMap { Range($0.range(at: 2), in: output) }
            .map { String(output[$0]) } ?? "0:00"
        let coverageRatio = mmssToSeconds(finalSectionTs).flatMap { fs in
            mmssToSeconds(finalTranscriptTs).map { ft in
                ft <= 0 ? 1.0 : min(1.0, Double(fs) / Double(ft))
            }
        } ?? 0.0
        if coverageRatio < 0.85 {
            notes.append("Coverage gap: final section \(finalSectionTs), transcript ends \(finalTranscriptTs)")
        }

        // Anti-padding — count filler phrases.
        let fillerPhrases = [
            "emphasized the importance of",
            "discussed the various",
            "highlighted the importance",
            "would be working with several",
            "talked about plans for the mission",
            "various opportunities and meetings",
        ]
        var fillerHits = 0
        let lower = output.lowercased()
        for phrase in fillerPhrases {
            fillerHits += countOccurrences(of: phrase, in: lower)
        }
        let fillerScore = fillerHits == 0 ? 1.0 : max(0.0, 1.0 - Double(fillerHits) * 0.2)
        if fillerHits > 0 { notes.append("Filler phrases: \(fillerHits)") }

        // No participant dump — Speakers lines should not list every
        // participant. Heuristic: if any **Speakers**: line contains 80%+
        // of the participants, that section is dumping.
        let speakersRegex = try! NSRegularExpression(pattern: #"\*\*Speakers\*\*:\s*([^\n]+)"#)
        let speakerMatches = speakersRegex.matches(in: output, range: nsRange)
        var dumpedSections = 0
        for match in speakerMatches {
            guard let r = Range(match.range(at: 1), in: output) else { continue }
            let speakerLine = String(output[r])
            let listed = speakerLine.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let listedSet = Set(listed.map { $0.lowercased() })
            let participantSet = Set(fixture.participants.map { $0.lowercased() })
            // If listed includes 80%+ of participants AND >= 4 names, it's a dump.
            let overlap = listedSet.intersection(participantSet).count
            let participantThreshold = max(4, Int(Double(participantSet.count) * 0.8))
            if overlap >= participantThreshold && participantSet.count >= 4 {
                dumpedSections += 1
            }
        }
        let dumpScore = dumpedSections == 0 ? 1.0 : max(0.0, 1.0 - Double(dumpedSections) / max(1.0, Double(speakerMatches.count)))
        if dumpedSections > 0 { notes.append("Speakers dump in \(dumpedSections) sections") }

        // No forbidden names
        for forbidden in fixture.forbiddenNames {
            if lower.contains(forbidden.lowercased()) {
                notes.append("Forbidden name: \(forbidden)")
            }
        }

        let primary = (bandScore + coverageRatio + fillerScore + dumpScore) / 4.0
        return ScoreResult(
            primary: primary,
            secondary: [
                "section_count_in_band": bandScore,
                "transcript_coverage":   coverageRatio,
                "no_filler":             fillerScore,
                "no_speakers_dump":      dumpScore,
                "section_count":         min(1.0, Double(sectionCount) / Double(highBand)),
            ],
            notes: notes,
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Helpers

    /// Strips a leading ```json ... ``` Markdown code fence if present.
    /// Many models wrap their JSON despite "JSON only" instructions.
    private static func stripCodeFence(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop any chatter before the first { or [.
        if let first = s.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            s = String(s[first...])
        }
        // Drop trailing chatter after the last } or ].
        if let last = s.lastIndex(where: { $0 == "}" || $0 == "]" }) {
            s = String(s[...last])
        }
        return s
    }

    private static func mmssToSeconds(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let m = Int(parts[0]), let sec = Int(parts[1]) else { return nil }
        return m * 60 + sec
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
