import Foundation

// MARK: - CLI parse

struct CLIOptions {
    var promptKinds: [PromptKind] = PromptKind.allCases
    var models: [String] = ["qwen3:4b", "qwen3:8b"]
    var fixturesDir: URL = URL(fileURLWithPath: "Tests/PromptOptimization/Fixtures")
    var resultsDir: URL = URL(fileURLWithPath: "Tests/PromptOptimization/results")
}

func parseCLI() -> CLIOptions {
    var opts = CLIOptions()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--prompt", "-p":
            if let value = args.next(), let kind = PromptKind(rawValue: value) {
                opts.promptKinds = [kind]
            }
        case "--model", "-m":
            if let value = args.next() {
                opts.models = [value]
            }
        case "--fixtures":
            if let value = args.next() {
                opts.fixturesDir = URL(fileURLWithPath: value)
            }
        case "--results":
            if let value = args.next() {
                opts.resultsDir = URL(fileURLWithPath: value)
            }
        case "--help", "-h":
            print("""
            prompt-eval — score candidate prompts against fixture transcripts.

            Usage:
              prompt-eval [--prompt <kind>] [--model <name>] [--fixtures <dir>] [--results <dir>]

            Options:
              --prompt <kind>    Restrict to one prompt kind (\(PromptKind.allCases.map { $0.rawValue }.joined(separator: ", "))).
                                 Default: all kinds.
              --model <name>     Restrict to one model (e.g. qwen3:4b, qwen3:8b).
                                 Default: qwen3:4b + qwen3:8b.
              --fixtures <dir>   Directory of fixture subdirs.
                                 Default: Tests/PromptOptimization/Fixtures
              --results <dir>    Where to write the JSON report.
                                 Default: Tests/PromptOptimization/results
            """)
            exit(0)
        default:
            break
        }
    }
    return opts
}

// MARK: - Run

func runHarness() async throws {
    let opts = parseCLI()
    let client = OllamaClient()
    let fixtures = try FixtureLoader.loadAll(from: opts.fixturesDir)
    guard !fixtures.isEmpty else {
        print("No fixtures found in \(opts.fixturesDir.path)")
        exit(1)
    }

    // Refuse to run while the live Meeting Manager app is running. The
    // earlier run was OOM-killed (exit 137) when the harness, the app's
    // detailedOutline backfill, AND a parallel Ollama model pull all hit
    // memory together — the harness shares a single Ollama process with
    // the app, and only one heavy generation should run at a time.
    //
    // We check process presence rather than reading the live DB because
    // the app holds a GRDB write lock that hangs sqlite3 reads. Process
    // presence is a more conservative + faster signal anyway: even if
    // the queue is empty, the app's WhisperKit model is resident, and
    // adding heavy LLM load risks the same OOM.
    if liveAppIsRunning() {
        print("⚠️  Meeting Manager is currently running.")
        print("   Running the harness now will compete with the app for memory")
        print("   and may OOM-kill one of the processes (it did, last time).")
        print("   Quit Meeting Manager (⌘Q from the app) and re-run prompt-eval.")
        exit(3)
    }

    print("Fixtures: \(fixtures.count) — \(fixtures.map { $0.id }.joined(separator: ", "))")
    print("Models:   \(opts.models.joined(separator: ", "))")
    print("Prompts:  \(opts.promptKinds.map { $0.rawValue }.joined(separator: ", "))")
    print()

    var report: [String: Any] = [
        "ranAt": ISO8601DateFormatter().string(from: Date()),
        "fixtures": fixtures.map { $0.id },
        "models": opts.models,
        "results": [String: Any](),
    ]
    var resultsByKind: [String: Any] = [:]

    for kind in opts.promptKinds {
        print("==== \(kind.rawValue) ====")
        var resultsByModel: [String: Any] = [:]

        for model in opts.models {
            print(" -- model: \(model) --")
            var resultsByCandidate: [String: Any] = [:]

            for candidate in kind.candidates {
                print("    candidate: \(candidate.id)")
                var fixtureScores: [(fixtureId: String, primary: Double, secondary: [String: Double], notes: [String], elapsed: Double)] = []

                for fixture in fixtures {
                    do {
                        let result = try await client.generate(
                            model: model,
                            systemPrompt: candidate.systemPrompt,
                            userPrompt: candidate.userPrompt(for: fixture),
                            options: OllamaClient.GenerateOptions(
                                temperature: 0.3,
                                numPredict: kind == .outline ? 16384 : 4096,
                                numCtx: 32768
                            )
                        )
                        let score = scoreFor(kind: kind, output: result.text, fixture: fixture, elapsed: result.elapsedSeconds)
                        fixtureScores.append((
                            fixtureId: fixture.id,
                            primary: score.primary,
                            secondary: score.secondary,
                            notes: score.notes,
                            elapsed: score.elapsedSeconds
                        ))
                        let secStr = score.secondary
                            .sorted(by: { $0.key < $1.key })
                            .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
                            .joined(separator: " ")
                        let noteStr = score.notes.isEmpty ? "" : " | " + score.notes.joined(separator: "; ")
                        print(String(format: "        %-22s primary=%.2f %@%@ (%.1fs)",
                                     fixture.id, score.primary, secStr, noteStr, score.elapsedSeconds))
                    } catch {
                        print("        \(fixture.id) ERROR: \(error.localizedDescription)")
                        fixtureScores.append((
                            fixtureId: fixture.id,
                            primary: 0,
                            secondary: [:],
                            notes: ["error: \(error.localizedDescription)"],
                            elapsed: 0
                        ))
                    }
                }

                let avgPrimary = fixtureScores.map { $0.primary }.reduce(0, +) / Double(max(fixtureScores.count, 1))
                let avgElapsed = fixtureScores.map { $0.elapsed }.reduce(0, +) / Double(max(fixtureScores.count, 1))
                print(String(format: "        ── avg primary: %.2f, avg elapsed: %.1fs ──", avgPrimary, avgElapsed))

                resultsByCandidate[candidate.id] = [
                    "avg_primary": avgPrimary,
                    "avg_elapsed_seconds": avgElapsed,
                    "fixtures": fixtureScores.map { fs in
                        [
                            "fixture": fs.fixtureId,
                            "primary": fs.primary,
                            "secondary": fs.secondary,
                            "notes": fs.notes,
                            "elapsed": fs.elapsed,
                        ] as [String: Any]
                    },
                ]
            }

            // Ranking print
            let ranked = resultsByCandidate
                .compactMap { (id, val) -> (String, Double)? in
                    guard let dict = val as? [String: Any], let p = dict["avg_primary"] as? Double else { return nil }
                    return (id, p)
                }
                .sorted(by: { $0.1 > $1.1 })
            print("    ranking:")
            for (idx, entry) in ranked.enumerated() {
                let medal = idx == 0 ? "🥇" : idx == 1 ? "🥈" : "  "
                print(String(format: "      %@ %-22s %.3f", medal, entry.0, entry.1))
            }
            print()

            resultsByModel[model] = resultsByCandidate
        }

        resultsByKind[kind.rawValue] = resultsByModel
    }

    report["results"] = resultsByKind

    // Write report
    try FileManager.default.createDirectory(at: opts.resultsDir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: ".", with: "-")
    let reportURL = opts.resultsDir.appendingPathComponent("eval-\(stamp).json")
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: reportURL)
    print("Report written: \(reportURL.path)")
}

func scoreFor(kind: PromptKind, output: String, fixture: Fixture, elapsed: Double) -> ScoreResult {
    switch kind {
    case .actionItem:  return Rubrics.scoreActionItem(output: output, fixture: fixture, elapsed: elapsed)
    case .attribution: return Rubrics.scoreAttribution(output: output, fixture: fixture, elapsed: elapsed)
    case .summary:     return Rubrics.scoreSummary(output: output, fixture: fixture, elapsed: elapsed)
    case .outline:     return Rubrics.scoreOutline(output: output, fixture: fixture, elapsed: elapsed)
    }
}

// MARK: - Live-app pause guard

/// True when the live Meeting Manager app is currently running. Faster +
/// more reliable than reading the app's DB (the app holds a GRDB write
/// lock that hangs sqlite3 reads). Process presence is also strictly
/// safer: even an idle app keeps WhisperKit resident, and adding heavy
/// LLM load on top still risks OOM.
func liveAppIsRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "MeetingManager"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        // pgrep exit 0 = found, 1 = not found
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

// MARK: - Top-level
//
// Use the explicit @main async pattern. Top-level `await` in a file named
// `main.swift` works in Swift 5.5+ but the runtime wraps it in a dispatch
// semaphore that conflicts with concurrent-queue work in the harness.
// `@main` with an `async` static `main()` is the cleaner pattern.

@main
struct PromptEval {
    static func main() async {
        do {
            try await runHarness()
        } catch {
            print("FATAL: \(error)")
            exit(2)
        }
    }
}
