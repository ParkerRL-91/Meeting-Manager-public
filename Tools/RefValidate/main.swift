import AVFoundation
import FluidAudio
import Foundation

// Make-or-break test for cross-meeting voice identity:
// 1. Build a reference embedding for a person from meeting A (cluster that
//    overlaps that person's known rows).
// 2. Enroll it when diarizing meeting B.
// 3. Check whether the cluster FluidAudio tags with the enrolled id actually
//    overlaps that person's known rows in B (recall), and how much non-person
//    time it wrongly captures (precision proxy).
//
// Input JSON (arg1): { "refWav","testWav", "refRows":[{start,end}], "testRows":[{start,end}] }
// refRows/testRows = the time spans the person is KNOWN to speak (from labels).

struct Span: Codable { let start: Double; let end: Double }
struct Input: Codable { let refWav: String; let testWav: String; let refRows: [Span]; let testRows: [Span] }

func load16k(_ path: String) -> [Float]? {
    guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    let fmt = f.processingFormat
    guard fmt.sampleRate == 16000, let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
    try? f.read(into: b)
    guard let ch = b.floatChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(b.frameLength)))
}
func overlap(_ aS: Double, _ aE: Double, _ spans: [Span]) -> Double {
    var t = 0.0
    for s in spans { t += max(0, min(aE, s.end) - max(aS, s.start)) }
    return t
}

let args = CommandLine.arguments
guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]),
      let inp = try? JSONDecoder().decode(Input.self, from: data) else { print("usage: ref-validate <input.json>"); exit(1) }

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
log("loading models…")
let models = try await DiarizerModels.downloadIfNeeded()
let diar = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.7))
diar.initialize(models: models)

// --- Build reference from meeting A ---
guard let refSamples = load16k(inp.refWav) else { print("cannot load refWav"); exit(1) }
let refResult = try diar.performCompleteDiarization(refSamples, sampleRate: 16000)
// cluster with most overlap to the person's known rows
var ovByCluster: [String: Double] = [:]
var embByCluster: [String: [[Float]]] = [:]
for seg in refResult.segments {
    let ov = overlap(Double(seg.startTimeSeconds), Double(seg.endTimeSeconds), inp.refRows)
    if ov > 0 { ovByCluster[seg.speakerId, default: 0] += ov }
    embByCluster[seg.speakerId, default: []].append(seg.embedding)
}
guard let personCluster = ovByCluster.max(by: { $0.value < $1.value })?.key else { print("no overlapping cluster in ref meeting"); exit(1) }
let embs = embByCluster[personCluster] ?? []
let dim = embs.first?.count ?? 0
var mean = [Float](repeating: 0, count: dim)
for e in embs { for i in 0..<dim { mean[i] += e[i] } }
for i in 0..<dim { mean[i] /= Float(max(1, embs.count)) }
log("ref meeting: \(refResult.segments.count) segs, person=cluster \(personCluster) (\(embs.count) segs), embDim=\(dim)")

// --- Enroll + diarize meeting B ---
diar.speakerManager.initializeKnownSpeakers([], mode: .reset, preserveIfPermanent: false)
let userSpeaker = Speaker(id: "USER", name: "Parker", currentEmbedding: mean, isPermanent: true)
diar.speakerManager.initializeKnownSpeakers([userSpeaker], mode: .reset, preserveIfPermanent: false)
guard let testSamples = load16k(inp.testWav) else { print("cannot load testWav"); exit(1) }
let testResult = try diar.performCompleteDiarization(testSamples, sampleRate: 16000)

// Which cluster(s) got tagged "USER"? How much do they overlap the person's known rows in B?
let clusters = Set(testResult.segments.map { $0.speakerId })
var userTime = 0.0, userPersonOverlap = 0.0, totalPersonTime = 0.0
for s in inp.testRows { totalPersonTime += (s.end - s.start) }
var matchedOnPersonRows = 0.0
for seg in testResult.segments {
    let dur = Double(seg.endTimeSeconds - seg.startTimeSeconds)
    let ovP = overlap(Double(seg.startTimeSeconds), Double(seg.endTimeSeconds), inp.testRows)
    if seg.speakerId == "USER" { userTime += dur; userPersonOverlap += ovP }
    if ovP > dur * 0.5 { /* this seg is mostly on the person's known rows */
        if seg.speakerId == "USER" { matchedOnPersonRows += ovP }
    }
}
let recall = totalPersonTime > 0 ? userPersonOverlap / totalPersonTime : 0
let precision = userTime > 0 ? userPersonOverlap / userTime : 0
log("test meeting: \(testResult.segments.count) segs, clusters=\(clusters.sorted())")
log(String(format: "USER-tagged time=%.0fs, of which on person's known rows=%.0fs", userTime, userPersonOverlap))
log(String(format: "RECALL (person time captured by USER tag)=%.0f%%  PRECISION (USER time that is really the person)=%.0f%%", recall * 100, precision * 100))
let verdict = (clusters.contains("USER") && recall > 0.5 && precision > 0.6) ? "PASS" : "WEAK/FAIL"
log("VERDICT: \(verdict)  (PASS = enrolled voice reliably re-identifies the person across meetings)")
