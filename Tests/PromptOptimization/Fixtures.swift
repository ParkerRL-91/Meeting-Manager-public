import Foundation

/// Loaded fixture: a transcript blob plus the ground-truth metadata used
/// by every rubric. Metadata is hand-authored when the fixture is created
/// (see Tests/PromptOptimization/Fixtures/<id>/meta.json).
struct Fixture {
    let id: String
    let title: String
    let date: String
    let durationSeconds: Int
    let participants: [String]
    let expectedSpeakers: [String]
    let expectedActionItems: [ExpectedActionItem]
    let expectedDecisions: [String]
    let expectedTopics: [String]
    let forbiddenNames: [String]
    let namesNotInParticipantsButMentioned: [String]
    let transcriptText: String
}

struct ExpectedActionItem {
    let who: String
    let what: String
}

enum FixtureLoader {
    /// Load every fixture under `Tests/PromptOptimization/Fixtures/<id>/`.
    /// Each subdirectory must contain `transcript.md` + `meta.json`.
    /// Returns fixtures sorted by id for deterministic iteration order.
    static func loadAll(from rootDir: URL) throws -> [Fixture] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil)) ?? []
        var fixtures: [Fixture] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let transcriptURL = entry.appendingPathComponent("transcript.md")
            let metaURL = entry.appendingPathComponent("meta.json")
            guard fm.fileExists(atPath: transcriptURL.path),
                  fm.fileExists(atPath: metaURL.path) else { continue }

            let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
            let metaData = try Data(contentsOf: metaURL)
            guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
                continue
            }
            fixtures.append(makeFixture(meta: meta, transcript: transcript))
        }
        return fixtures
    }

    private static func makeFixture(meta: [String: Any], transcript: String) -> Fixture {
        let actionItems: [ExpectedActionItem] = (meta["expectedActionItems"] as? [[String: String]] ?? [])
            .map { ExpectedActionItem(who: $0["who"] ?? "", what: $0["what"] ?? "") }

        return Fixture(
            id: meta["fixtureId"] as? String ?? "",
            title: meta["meetingTitle"] as? String ?? "",
            date: meta["date"] as? String ?? "",
            durationSeconds: meta["durationSeconds"] as? Int ?? 0,
            participants: meta["participants"] as? [String] ?? [],
            expectedSpeakers: meta["expectedSpeakers"] as? [String] ?? [],
            expectedActionItems: actionItems,
            expectedDecisions: meta["expectedDecisions"] as? [String] ?? [],
            expectedTopics: meta["expectedTopics"] as? [String] ?? [],
            forbiddenNames: meta["forbiddenNames"] as? [String] ?? [],
            namesNotInParticipantsButMentioned: meta["namesNotInParticipantsButMentioned"] as? [String] ?? [],
            transcriptText: transcript
        )
    }
}
