import AVFoundation
import FluidAudio
import Foundation

// Batch re-diarize + re-attribute collapsed meetings, OFFLINE and REVIEWABLE.
// Reads a job JSON, diarizes each meeting's mixed WAV with FluidAudio, aligns
// clusters to existing transcript rows, asks the local model (Ollama, JSON-
// constrained to that meeting's attendees) to map Speaker N -> attendee, and
// EMITS SQL (no DB writes). Clusters it can't place stay "Speaker N".
//
// Usage: batch-rediarize <jobs.json> <out.sql>
// jobs.json: [{ "meetingId": "...", "wav": "/abs/path.wav",
//               "attendees": ["Name <email>", ...],
//               "rows": [{ "id": 123, "start": 1.2, "end": 4.5, "text": "..." }] }]

struct Row: Codable { let id: Int64; let start: Double; let end: Double; let text: String }
struct Job: Codable { let meetingId: String; let wav: String; let attendees: [String]; let rows: [Row] }

func loadMono16k(_ path: String) -> [Float]? {
    guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    let fmt = f.processingFormat
    guard fmt.sampleRate == 16000,
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
    do { try f.read(into: buf) } catch { return nil }
    guard let ch = buf.floatChannelData else { return nil }
    var s = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    if let cap = Double(ProcessInfo.processInfo.environment["MAX_SECONDS"] ?? ""), cap > 0 {
        let n = Int(cap * 16000); if s.count > n { s = Array(s[0..<n]) }
    }
    return s
}

func sqlEscape(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

/// Ask Ollama (JSON-constrained, closed attendee set) to map each "Speaker N"
/// to an attendee or "Unknown". Returns [speakerLabel: attendee].
func attributeViaOllama(speakers: [(label: String, sample: String)], attendees: [String], model: String) async -> [String: String] {
    guard !speakers.isEmpty, !attendees.isEmpty else { return [:] }
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "assignments": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "speaker": ["type": "string"],
                        "attendee": ["type": "string"],
                    ],
                    "required": ["speaker", "attendee"],
                ],
            ],
        ],
        "required": ["assignments"],
    ]
    let attendeeList = attendees.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    let speakerBlock = speakers.map { "\($0.label):\n\"\($0.sample.prefix(1200))\"" }.joined(separator: "\n\n")
    let system = """
    You map anonymous meeting speakers to the meeting's attendees using what each speaker says.
    Rules: assign each speaker to EXACTLY ONE attendee from the list, or "Unknown" if you cannot tell.
    Use ONLY names/emails from the attendee list verbatim. Do not invent anyone. It's fine to leave speakers Unknown.
    """
    let user = "ATTENDEES:\n\(attendeeList)\n\nSPEAKERS (with sample quotes):\n\(speakerBlock)\n\nReturn the assignment for every speaker."
    let body: [String: Any] = [
        "model": model,
        "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        "stream": false,
        "think": false,
        "format": schema,
        "options": ["temperature": 0],
    ]
    guard let url = URL(string: "http://localhost:11434/api/chat"),
          let data = try? JSONSerialization.data(withJSONObject: body) else { return [:] }
    var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = data
    req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.timeoutInterval = 180
    guard let (respData, _) = try? await URLSession.shared.data(for: req),
          let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
          let msg = obj["message"] as? [String: Any],
          let content = msg["content"] as? String,
          let parsed = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
          let assignments = parsed["assignments"] as? [[String: Any]] else { return [:] }
    // Validate every returned attendee against the closed set (case-insensitive).
    let lc = Dictionary(uniqueKeysWithValues: attendees.map { ($0.lowercased(), $0) })
    var out: [String: String] = [:]
    for a in assignments {
        guard let sp = a["speaker"] as? String, let at = a["attendee"] as? String else { continue }
        if let canon = lc[at.lowercased()] { out[sp] = canon }
    }
    return out
}

// ── main ──────────────────────────────────────────────────────────────────
let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: batch-rediarize <jobs.json> <out.sql>\n".utf8)); exit(1) }
let model = ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "qwen3:8b"
guard let jobsData = FileManager.default.contents(atPath: args[1]),
      let jobs = try? JSONDecoder().decode([Job].self, from: jobsData) else {
    FileHandle.standardError.write(Data("failed to read/parse jobs json\n".utf8)); exit(1)
}

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
log("Loading FluidAudio diarizer models…")
let models = try await DiarizerModels.downloadIfNeeded()
let env = ProcessInfo.processInfo.environment
let threshold = Float(env["CLUSTERING_THRESHOLD"] ?? "") ?? 0.7
let skipNaming = env["SKIP_NAMING"] == "1"
let diarizer = DiarizerManager(config: DiarizerConfig(clusteringThreshold: threshold))
diarizer.initialize(models: models)
log("clusteringThreshold=\(threshold) skipNaming=\(skipNaming)")

// Stream SQL to disk per-meeting so a mid-run crash can't lose progress.
// No BEGIN/COMMIT here — apply wraps the file in a transaction.
FileManager.default.createFile(atPath: args[2], contents: nil)
guard let out = FileHandle(forWritingAtPath: args[2]) else {
    log("cannot open output \(args[2])"); exit(1)
}
func emit(_ s: String) { out.write(Data(s.utf8)) }
var totalNamed = 0, totalSplit = 0, meetingsDone = 0

for (idx, job) in jobs.enumerated() {
    guard let samples = loadMono16k(job.wav) else { log("  [\(job.meetingId)] SKIP: cannot load \(job.wav)"); continue }
    guard let result = try? diarizer.performCompleteDiarization(samples, sampleRate: 16000) else {
        log("  [\(job.meetingId)] SKIP: diarization failed"); continue
    }
    diarizer.speakerManager.initializeKnownSpeakers([], mode: .reset, preserveIfPermanent: false)

    // Map raw cluster ids -> deterministic 1-based "Speaker N".
    var clusterNum: [String: Int] = [:]; var next = 1
    func labelFor(_ raw: String) -> String {
        if let n = clusterNum[raw] { return "Speaker \(n)" }
        clusterNum[raw] = next; defer { next += 1 }; return "Speaker \(next)"
    }
    // Assign each transcript row to the best-overlapping cluster.
    var rowLabel: [Int64: String] = [:]
    var clusterText: [String: String] = [:]
    for row in job.rows {
        var best: String? = nil; var bestOv = 0.0
        for seg in result.segments {
            let ov = max(0, min(row.end, Double(seg.endTimeSeconds)) - max(row.start, Double(seg.startTimeSeconds)))
            if ov > bestOv { bestOv = ov; best = seg.speakerId }
        }
        guard let raw = best, bestOv > 0 else { continue }
        let label = labelFor(raw)
        rowLabel[row.id] = label
        if clusterText[label, default: ""].count < 1400 { clusterText[label, default: ""] += row.text + " " }
    }
    let speakerCount = clusterNum.count
    let speakers = clusterText.map { (label: $0.key, sample: $0.value) }.sorted { $0.label < $1.label }

    // Closed-set attribution via local model (skippable for fast count checks).
    let mapping = skipNaming ? [:] : await attributeViaOllama(speakers: speakers, attendees: job.attendees, model: model)

    var speakerMapJSON: [String: String] = [:]
    var meetingSQL = "-- meeting \(job.meetingId): \(speakerCount) speakers\n"
    for (rowId, label) in rowLabel {
        let resolved = mapping[label]
        let finalLabel = resolved ?? label
        if resolved != nil { speakerMapJSON[label] = resolved }
        meetingSQL += "UPDATE transcript SET speakerLabel='\(sqlEscape(finalLabel))' WHERE id=\(rowId);\n"
    }
    let namedClusters = Set(speakerMapJSON.values).count
    if !speakerMapJSON.isEmpty,
       let mapData = try? JSONSerialization.data(withJSONObject: speakerMapJSON),
       let mapStr = String(data: mapData, encoding: .utf8) {
        meetingSQL += "UPDATE meeting SET speakerMap='\(sqlEscape(mapStr))' WHERE id='\(sqlEscape(job.meetingId))';\n"
    }
    emit(meetingSQL)   // flush per meeting — crash-safe
    totalNamed += namedClusters; totalSplit += (speakerCount > 1 ? 1 : 0); meetingsDone += 1
    log("  [\(idx + 1)/\(jobs.count)] \(job.meetingId): \(speakerCount) speakers, \(namedClusters) named (\(mapping.values.sorted().joined(separator: ", ")))")
}
emit("-- DONE\n")
try? out.close()
log("\n=== DONE: \(meetingsDone) meetings, \(totalSplit) split into >1 speaker, \(totalNamed) total named clusters ===")
log("SQL written to \(args[2]) — REVIEW before applying.")
