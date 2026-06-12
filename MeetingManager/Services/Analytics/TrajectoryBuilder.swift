import Foundation

/// Topic trajectories (TASK-057): "everything we said about X, in order".
/// A pure view over hits the search sheet already produces — semantic
/// chunks + FTS snippets merged to ONE point per meeting (review m5:
/// per-meeting granularity), sorted oldest→newest so a stance change
/// reads top to bottom. No tables, no stored state.
enum TrajectoryBuilder {

    struct Point: Equatable, Identifiable {
        let meetingId: String
        let title: String
        let date: Date
        let excerpt: String
        /// ≤8-word stance label, filled in by the optional LLM pass.
        var stance: String? = nil
        var id: String { meetingId }
    }

    /// Most recent N meetings make the timeline — older points drop first.
    static let pointCap = 12
    static let excerptCap = 220

    static func build(semanticHits: [(meetingId: String, text: String, score: Float)],
                      ftsHits: [(meetingId: String, snippet: String)],
                      meetings: [Meeting],
                      cap: Int = pointCap) -> [Point] {
        let byId = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })

        // Best semantic chunk per meeting wins; FTS fills meetings the
        // semantic pass missed (or covers everything when embeddings are
        // unavailable).
        var bestSemantic: [String: (text: String, score: Float)] = [:]
        for hit in semanticHits {
            if let existing = bestSemantic[hit.meetingId], existing.score >= hit.score { continue }
            bestSemantic[hit.meetingId] = (hit.text, hit.score)
        }
        var excerpts: [String: String] = bestSemantic.mapValues(\.text)
        for hit in ftsHits where excerpts[hit.meetingId] == nil {
            excerpts[hit.meetingId] = hit.snippet
        }

        let points = excerpts.compactMap { meetingId, text -> Point? in
            guard let meeting = byId[meetingId] else { return nil }
            return Point(meetingId: meetingId,
                         title: meeting.title,
                         date: meeting.effectiveDate,
                         excerpt: clip(text))
        }.sorted { $0.date < $1.date }
        return Array(points.suffix(cap))
    }

    static func clip(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return t.count <= excerptCap ? t : String(t.prefix(excerptCap)) + "…"
    }

    // MARK: Stance labels (optional LLM pass — routed through the broker,
    // review m5: the user just clicked Timeline, this is interactive work)

    static let stanceSchemaJSON = """
    {"type":"object","properties":{"labels":{"type":"array","items":{"type":"object","properties":{"index":{"type":"integer"},"stance":{"type":"string"}},"required":["index","stance"]}}},"required":["labels"]}
    """

    static let stanceSystemPrompt = """
    You label what was said about a topic at each point in time. For each \
    numbered excerpt, return a stance label of AT MOST 8 words capturing \
    the position, decision, or state at that moment — e.g. "leaning toward \
    vendor B", "pricing still unresolved", "agreed to ship Friday". Use \
    only the excerpt's content; if it doesn't address the topic, label it \
    "mentioned in passing". Return ONLY JSON matching the requested shape.
    """

    static func stanceUserPrompt(topic: String, points: [Point]) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let body = points.enumerated().map { i, p in
            "Point \(i) (\(df.string(from: p.date))): \(p.excerpt)"
        }.joined(separator: "\n\n")
        return "Topic: \(topic)\n\n\(body)"
    }

    struct StancePayload: Decodable {
        struct Entry: Decodable { let index: Int; let stance: String }
        let labels: [Entry]
    }

    /// Apply parsed labels; clamps to 8 words defensively.
    static func applyStances(_ response: String, to points: [Point]) -> [Point] {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              let payload = try? JSONDecoder().decode(StancePayload.self,
                                                      from: Data(String(response[start...end]).utf8))
        else { return points }
        var out = points
        for entry in payload.labels where entry.index >= 0 && entry.index < out.count {
            let words = entry.stance.split(separator: " ").prefix(8)
            let label = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { out[entry.index].stance = label }
        }
        return out
    }
}
