import AVFoundation
import FluidAudio
import Foundation

// Non-destructive validation of the speaker-naming foundation: the P1 energy
// "you" anchor (AppState.identifyUserClusterByEnergy). For each meeting we
// diarize the MIXED track with FluidAudio, score each cluster's mic-vs-system
// energy exactly as the app does, predict the user's cluster, and compare it
// to ground truth built from EXISTING transcript labels. Writes no DB.
//
// Ground-truth design (avoids circularity): prefer meetings whose Parker rows
// were labeled by LLM/manual ("gold"), not the old energy heuristic (".s").
// We also report, for the predicted cluster, the dominant overlapping label
// and the user-purity — so even imperfect labels expose a wrong pick.
//
// Input JSON (arg1): [{ meetingId, mixedWav, systemWav,
//   userLabels:[String], rows:[{label,start,end}] }]  rows = all NAMED rows.

struct Row: Codable { let label: String; let start: Double; let end: Double }
struct Job: Codable { let meetingId: String; let mixedWav: String; let systemWav: String; let userLabels: [String]; let rows: [Row] }

func load16k(_ path: String) -> [Float]? {
    guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    let fmt = f.processingFormat
    guard fmt.sampleRate == 16000, let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
    try? f.read(into: b)
    guard let ch = b.floatChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(b.frameLength)))
}
func rms(_ b: [Float], _ s: Int, _ e: Int) -> Float {
    guard s < e, s >= 0, e <= b.count else { return -1 }
    var sum: Float = 0, i = s
    while i < e { sum += b[i]*b[i]; i += 1 }
    return sqrtf(sum / Float(e - s))
}
func ov(_ aS: Double, _ aE: Double, _ bS: Double, _ bE: Double) -> Double { max(0, min(aE, bE) - max(aS, bS)) }

let args = CommandLine.arguments
guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]),
      let jobs = try? JSONDecoder().decode([Job].self, from: data) else { print("usage: naming-validate <jobs.json>"); exit(1) }
func log(_ s: String) { FileHandle.standardError.write(Data((s+"\n").utf8)); FileHandle.standardError.synchronizeFile() }

log("loading FluidAudio models…")
let models = try await DiarizerModels.downloadIfNeeded()
let diar = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.7))
diar.initialize(models: models)

let sr = 16000.0
let speechFloor: Float = 0.005
let userRatio: Float = 0.35

var correct = 0, attempted = 0, abstained = 0, total = 0, goldCorrect = 0, goldAttempted = 0
print("meetingId,kind,clusters,predicted,trueUser,energyFrac,margin,result,predDominantLabel,predUserPurity")
for (idx, job) in jobs.enumerated() {
    total += 1
    // Gold jobs are marked by a "<self-name>.s" user label. Set NAMING_SELF_LABEL
    // to your own self-name locally; defaults to "Self" so no name is hardcoded.
    let selfLabel = ProcessInfo.processInfo.environment["NAMING_SELF_LABEL"] ?? "Self"
    let isGold = !job.userLabels.contains("\(selfLabel).s")
    diar.speakerManager.initializeKnownSpeakers([], mode: .reset, preserveIfPermanent: false)
    guard let mixed = load16k(job.mixedWav), let system = load16k(job.systemWav),
          !mixed.isEmpty, !system.isEmpty,
          let result = try? diar.performCompleteDiarization(mixed, sampleRate: 16000) else {
        print("\(job.meetingId.prefix(8)),\(isGold ? "gold":"cons"),LOAD_FAIL,,,,skip,,"); log("  [\(idx+1)/\(jobs.count)] LOAD_FAIL"); continue
    }
    var ranges: [String: [(Double, Double)]] = [:]
    for s in result.segments { ranges[s.speakerId, default: []].append((Double(s.startTimeSeconds), Double(s.endTimeSeconds))) }

    // FINDING: persisted mixed and system WAVs do NOT share a sample timeline
    // (mixed ≈ 3× system frames despite both being labeled 16kHz). Align the
    // system index to the mixed timeline by PROPORTION (both cover the same
    // recording wall-clock, just at different effective rates). systemScale<1
    // here. The shipped identifyUserClusterByEnergy assumes scale==1 — that is
    // the bug this run isolates.
    let systemScale = mixed.isEmpty ? 1.0 : Double(system.count) / Double(mixed.count)

    // P1 energy anchor — mirrors identifyUserClusterByEnergy, but TIME-ALIGNED.
    var bestCluster: String?; var bestFrac: Float = 0; var secondFrac: Float = 0; var anySystemSpeech = false
    for (cluster, rs) in ranges {
        var userWin = 0, totalWin = 0
        for r in rs {
            let s = Int(r.0*sr), e = Int(r.1*sr)
            let m = rms(mixed, s, e); if m < 0 || m <= speechFloor { continue }
            let ss = Int(Double(s)*systemScale), se = Int(Double(e)*systemScale)
            let sy = rms(system, min(ss, system.count), min(se, system.count)); if sy < 0 { continue }
            if sy > speechFloor { anySystemSpeech = true }
            totalWin += 1; if sy <= m * userRatio { userWin += 1 }
        }
        guard totalWin >= 3 else { continue }
        let frac = Float(userWin)/Float(totalWin)
        if frac > bestFrac { secondFrac = bestFrac; bestFrac = frac; bestCluster = cluster }
        else if frac > secondFrac { secondFrac = frac }
    }
    let predicted = (anySystemSpeech && bestFrac >= 0.7) ? bestCluster : nil

    // For every cluster, overlap (seconds) with each label.
    func labelOverlap(_ cluster: String) -> [String: Double] {
        var acc: [String: Double] = [:]
        for r in ranges[cluster] ?? [] { for row in job.rows { let o = ov(r.0, r.1, row.start, row.end); if o > 0 { acc[row.label, default: 0] += o } } }
        return acc
    }
    // trueUser cluster = max overlap with the user's labeled rows.
    var trueCluster: String?; var bestUserOv = 0.0
    for (cluster, _) in ranges {
        let lo = labelOverlap(cluster)
        let userOv = job.userLabels.reduce(0.0) { $0 + (lo[$1] ?? 0) }
        if userOv > bestUserOv { bestUserOv = userOv; trueCluster = cluster }
    }
    // Predicted cluster diagnostics.
    var predDom = "-"; var predPurity = "-"
    if let p = predicted {
        let lo = labelOverlap(p)
        let userOv = job.userLabels.reduce(0.0) { $0 + (lo[$1] ?? 0) }
        let totalOv = lo.values.reduce(0,+)
        let dom = lo.max { $0.value < $1.value }
        predDom = dom?.key ?? "(none)"
        predPurity = totalOv > 0 ? String(format: "%.2f", userOv/totalOv) : "n/a"
    }

    let res: String
    if predicted == nil { abstained += 1; res = "abstain" }
    else { attempted += 1; if isGold { goldAttempted += 1 }; if predicted == trueCluster { correct += 1; if isGold { goldCorrect += 1 }; res = "CORRECT" } else { res = "WRONG" } }
    print("\(job.meetingId.prefix(8)),\(isGold ? "gold":"cons"),\(ranges.count),\(predicted ?? "-"),\(trueCluster ?? "-"),\(String(format:"%.2f",bestFrac)),\(String(format:"%.2f",bestFrac-secondFrac)),\(res),\(predDom),\(predPurity)")
    log("  [\(idx+1)/\(jobs.count)] \(res)")
}
log("")
log("=== ENERGY ANCHOR VALIDATION ===")
log("meetings: \(total) | attempted: \(attempted) | abstained: \(abstained)")
let prec = attempted > 0 ? Double(correct)/Double(attempted)*100 : 0
log("overall: CORRECT \(correct)/\(attempted) = \(String(format:"%.0f",prec))%")
let gp = goldAttempted > 0 ? Double(goldCorrect)/Double(goldAttempted)*100 : 0
log("GOLD (non-.s, independent ground truth): CORRECT \(goldCorrect)/\(goldAttempted) = \(String(format:"%.0f",gp))%")
