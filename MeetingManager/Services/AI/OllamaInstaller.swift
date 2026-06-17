import Foundation
import AppKit
import os

// MARK: - Errors

enum OllamaInstallerError: LocalizedError {
    case downloadFailed(String)
    case installFailed(String)
    case launchFailed(String)
    case serverTimeout
    case pullFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let msg): return "Failed to download Ollama: \(msg)"
        case .installFailed(let msg): return "Failed to install Ollama: \(msg)"
        case .launchFailed(let msg): return "Failed to launch Ollama: \(msg)"
        case .serverTimeout: return "Ollama started but the server didn't come online. Try opening Ollama manually."
        case .pullFailed(let msg): return "Failed to download model: \(msg)"
        }
    }
}

// MARK: - OllamaInstaller

/// Handles downloading, installing, launching Ollama, and pulling a model — all in one flow.
/// Designed to be called when the user enables on-device summarization and Ollama isn't ready.
@Observable
@MainActor
final class OllamaInstaller {

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case downloadingApp(progress: Double)
        case installing
        case launching
        case waitingForServer
        case pullingModel(name: String, progress: Double)
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Ready to set up"
            case .downloadingApp(let p): return "Downloading Ollama (\(Int(p * 100))%)"
            case .installing: return "Installing Ollama..."
            case .launching: return "Starting Ollama..."
            case .waitingForServer: return "Waiting for Ollama to start..."
            case .pullingModel(let name, let p):
                let pct = Int(p * 100)
                return pct > 0 ? "Downloading \(name) (\(pct)%)" : "Downloading \(name)..."
            case .ready: return "Ready"
            case .failed(let msg): return "Failed: \(msg)"
            }
        }

        var progress: Double? {
            switch self {
            case .downloadingApp(let p): return p
            case .pullingModel(_, let p): return p > 0 ? p : nil
            default: return nil
            }
        }

        var isActive: Bool {
            switch self {
            case .idle, .ready, .failed: return false
            default: return true
            }
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    // MARK: - Properties

    private(set) var phase: Phase = .idle
    private(set) var ollamaAppURL: URL? = OllamaInstaller.findInstalledOllama()

    /// Single-flight set keyed by model tag. `@MainActor` isolation serializes
    /// the Set's mutations without locks. BOTH the foreground (`pullModel`) and
    /// background (`backgroundPullModel`) paths guard on membership before
    /// inserting and `defer`-remove on exit, so a duplicate same-tag pull backs
    /// off instead of racing `phase` or removing the tag from under a live pull.
    /// (Ollama's server also coalesces identical pulls; this guard only avoids
    /// redundant client connections and `phase` flicker — it does NOT prevent
    /// on-disk corruption.)
    private var inFlightPulls: Set<String> = []

    // MARK: - Public API

    var isOllamaInstalled: Bool {
        ollamaAppURL != nil
    }

    /// Full setup: installs Ollama if needed, launches it, pulls the model.
    ///
    /// `model = "auto"` is the user-facing default and historically was a
    /// latent bug — the literal string "auto" was passed to `ollama pull`,
    /// which fails. Resolution:
    ///   - "auto" → pull `OllamaService.smallTier` (e.g. qwen3:4b) in the
    ///     foreground, mark .ready, then opportunistically pull
    ///     `OllamaService.defaultTier` (qwen3:8b) in a detached background
    ///     task. The user becomes productive on the small tier immediately;
    ///     the larger tier arrives when it's done.
    ///   - any concrete model name → pull that exact model.
    func setupIfNeeded(model: String) async {
        // Check if Ollama is already installed
        let appURL: URL
        if let existing = Self.findInstalledOllama() {
            ollamaAppURL = existing
            appURL = existing
        } else {
            guard let downloaded = await downloadAndInstall() else { return }
            appURL = downloaded
        }

        // Launch Ollama if the server isn't already running
        if await !isServerReachable() {
            await launch(appURL: appURL)
            if case .failed = phase { return }
            await waitForServer()
            if case .failed = phase { return }
        }

        // Resolve "auto" to the small tier for the foreground pull, and
        // schedule the default tier as a background pull. Concrete model
        // names go straight through.
        let foregroundModel: String
        let backgroundModel: String?
        if model == "auto" {
            foregroundModel = OllamaService.smallTier
            backgroundModel = OllamaService.defaultTier
        } else {
            foregroundModel = model
            backgroundModel = nil
        }

        let available = await fetchAvailableModels()
        if !available.contains(foregroundModel) {
            await pullModel(foregroundModel)
        } else {
            phase = .ready
        }

        // Best-effort background pull for the default tier (Qwen3 8B).
        // Detached so we don't gate the user-visible .ready state on a
        // multi-GB download. Errors are swallowed — the adaptive selector
        // gracefully falls back to the small tier when the larger one is
        // missing.
        if let backgroundModel,
           !available.contains(backgroundModel),
           case .ready = phase {
            Task.detached { [weak self] in
                guard let self else { return }
                await self.backgroundPullModel(backgroundModel)
            }
        }
    }

    /// One-shot check: pull any missing model the user needs. Honors a
    /// concrete pin that is NOT a tier model (an explicit user choice such as
    /// `qwen2.5:3b-instruct`) exactly; otherwise runs the two-tier `auto`
    /// fan-out so the default population still gets the 8b background pull.
    /// No-op when nothing is missing. Cheap enough to call on every launch
    /// via `verifyLocalModelsOnStartup`.
    func verifyAndPullMissing(preferredModel: String) async {
        guard await isServerReachable() else { return }
        let available = await fetchAvailableModels()
        // Embedding model (TASK-045): small (~274 MB), pulled quietly in the
        // background. Semantic search degrades to FTS until it lands.
        if !available.contains(where: { $0.hasPrefix(EmbeddingService.embedModel) }) {
            Task { await self.backgroundPullModel(EmbeddingService.embedModel) }
        }

        // A concrete pin that is NOT a tier model is an explicit user choice
        // — honor it exactly. Otherwise fall through to the two-tier "auto"
        // fan-out so the 8b background pull is preserved for the default
        // population (ollamaModel defaults to smallTier, a concrete tag — see
        // AppSettings.swift). The default cannot distinguish "user pinned 4b"
        // from "user never chose", so a tier-equal pin keeps the fan-out.
        let isTierPin = preferredModel == OllamaService.smallTier
            || preferredModel == OllamaService.defaultTier
        if !preferredModel.isEmpty, preferredModel != "auto", !isTierPin {
            guard !available.contains(preferredModel) else { return }
            await setupIfNeeded(model: preferredModel)
            return
        }

        let missingSmall   = !available.contains(OllamaService.smallTier)
        let missingDefault = !available.contains(OllamaService.defaultTier)
        guard missingSmall || missingDefault else { return }
        // Non-blocking: kick off the background fan-out. setupIfNeeded
        // already does small-foreground + default-background.
        await setupIfNeeded(model: "auto")
    }

    /// Background pull variant — pulls the given model without flipping the
    /// public `phase` state away from `.ready`. The user keeps the small
    /// tier productive while this runs.
    private func backgroundPullModel(_ model: String) async {
        // A user-initiated (foreground) or another background pull of the same
        // tag is already running — don't race it. The foreground path drives
        // `phase`, so this back-off prevents the duplicate flicker.
        guard !inFlightPulls.contains(model) else { return }
        inFlightPulls.insert(model)
        defer { inFlightPulls.remove(model) }
        // Reuse the same pull endpoint pattern as `pullModel` but ignore
        // failures. Implementation kept inline to avoid restructuring the
        // existing pull path's progress reporting.
        guard let url = URL(string: "http://localhost:11434/api/pull") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 * 60   // 1 hour cap for large downloads
        let body: [String: Any] = ["name": model, "stream": false]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    func retry(model: String) async {
        phase = .idle
        await setupIfNeeded(model: model)
    }

    // MARK: - Install

    /// Minimum free disk space required for Ollama install + a small model (~5 GB).
    private static let minimumFreeDiskBytes: Int64 = 5 * 1024 * 1024 * 1024

    /// Pinned Ollama release. Bump this when adopting a new upstream version
    /// after smoke-testing the chat + pull endpoints we depend on. Using a
    /// fixed tag (not `releases/latest/`) means an upstream breaking change
    /// can't silently break summarization for new installs.
    static let pinnedOllamaVersion = "v0.24.0"

    private func downloadAndInstall() async -> URL? {
        // Check disk space before downloading
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeBytes = attrs[.systemFreeSize] as? Int64,
           freeBytes < Self.minimumFreeDiskBytes {
            let freeGB = freeBytes / (1024 * 1024 * 1024)
            phase = .failed("Not enough disk space. Need ~5 GB free, only \(freeGB) GB available.")
            return nil
        }

        // On Intel Macs, check that Rosetta 2 is available (Ollama may need it)
        #if arch(x86_64)
        if !fm.fileExists(atPath: "/Library/Apple/usr/share/rosetta") {
            Logger.ai.info("Running on Intel Mac — Rosetta check skipped (native x86_64)")
        }
        #else
        // Apple Silicon — no Rosetta needed
        #endif

        // Download Ollama-darwin.zip from GitHub. Pinned to a known-good
        // version (see pinnedOllamaVersion) instead of `releases/latest/`
        // so an upstream API break can't silently strand new installs.
        let downloadURL = URL(
            string: "https://github.com/ollama/ollama/releases/download/\(Self.pinnedOllamaVersion)/Ollama-darwin.zip"
        )!
        phase = .downloadingApp(progress: 0)

        let tempDir = fm.temporaryDirectory.appendingPathComponent("OllamaInstall-\(UUID().uuidString)")
        let zipPath = tempDir.appendingPathComponent("Ollama-darwin.zip")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create temp directory")
            return nil
        }

        // Download with progress (chunked for performance)
        do {
            try await downloadFile(from: downloadURL, to: zipPath) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.phase = .downloadingApp(progress: progress)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }

        // Unzip
        phase = .installing
        let unzipDir = tempDir.appendingPathComponent("unzipped")
        do {
            try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
            try await runProcess("/usr/bin/unzip", args: ["-o", zipPath.path, "-d", unzipDir.path])
        } catch {
            phase = .failed("Unzip failed: \(error.localizedDescription)")
            return nil
        }

        // Find Ollama.app in the unzipped contents
        let candidates = (try? fm.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)) ?? []
        guard let ollamaApp = candidates.first(where: { $0.lastPathComponent == "Ollama.app" }) else {
            phase = .failed("Ollama.app not found in download")
            return nil
        }

        // Verify code signature
        do {
            try await runProcess("/usr/bin/codesign", args: ["--verify", "--deep", ollamaApp.path])
        } catch {
            Logger.ai.warning("Ollama.app code signature verification failed: \(error.localizedDescription)")
            // Non-fatal — user may have downloaded a development build
        }

        // Move into our PRIVATE runtime dir (TASK-082 / ADR-016 A1), NOT
        // ~/Applications — so it never appears as a separate app/menu-bar/
        // updater. The whole signed .app is kept intact (server finds its
        // Metal runners by relative layout; signature stays valid).
        let runtimeDir = Self.privateRuntimeDir
        let dest = Self.privateRuntimeAppURL
        do {
            try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: ollamaApp, to: dest)
        } catch {
            phase = .failed("Could not install the on-device AI runtime: \(error.localizedDescription)")
            return nil
        }

        // Cleanup temp
        try? fm.removeItem(at: tempDir)

        ollamaAppURL = dest
        return dest
    }

    private func launch(appURL: URL) async {
        phase = .launching
        // Prefer launching the server binary directly at userInitiated QoS so
        // its inference threads are scheduled on the performance (P) cores. A
        // default/GUI-app launch can land the heavy work on the efficiency (E)
        // cores, which makes on-device summaries crawl. Only reached when no
        // server is already listening (the caller gates on isServerReachable),
        // so there's no port conflict with an existing instance.
        if let serverBinary = Self.findServerBinary(appURL: appURL) {
            let process = Process()
            process.executableURL = serverBinary
            process.arguments = ["serve"]
            process.qualityOfService = .userInitiated
            // Flash attention + q8_0 KV cache halve per-token KV memory
            // (~144 → ~72 KiB/token for qwen3) with negligible quality
            // impact — on the 16 GB baseline that's the difference between
            // the context window fitting alongside WhisperKit or spilling
            // to swap. Only effective when WE launch the server; a
            // user-launched instance keeps its own config, so the ADR-015
            // RAM bands still assume the f16 worst case — this is pure
            // headroom, never a dependency.
            var env = ProcessInfo.processInfo.environment
            env["OLLAMA_FLASH_ATTENTION"] = "1"
            env["OLLAMA_KV_CACHE_TYPE"] = "q8_0"
            // TASK-082: keep models in our private dir, not ~/.ollama, so the
            // runtime is self-contained and resettable. Only applied when WE
            // launch the bundled/private server; a user's own running Ollama
            // keeps its own config.
            env["OLLAMA_MODELS"] = Self.privateModelsDir.path
            try? FileManager.default.createDirectory(at: Self.privateModelsDir, withIntermediateDirectories: true)
            process.environment = env
            do {
                try process.run()
                Logger.ai.info("Ollama: launched `ollama serve` at userInitiated QoS with q8_0 KV cache (\(serverBinary.path, privacy: .public))")
                return
            } catch {
                Logger.ai.warning("Ollama: direct server launch failed (\(error.localizedDescription, privacy: .public)) — falling back to opening the app")
            }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do {
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            // NSWorkspace might throw even on success on some macOS versions — check if running
            Logger.ai.info("NSWorkspace.openApplication result: \(error.localizedDescription)")
        }
    }

    /// Locate the bundled `ollama` server binary so the server can be launched
    /// directly at an elevated QoS (P-cores). Falls through the common install
    /// locations; returns nil when none is executable, in which case the caller
    /// opens the GUI app instead (which schedules at its own QoS).
    private static func findServerBinary(appURL: URL) -> URL? {
        let candidates = [
            // Private runtime first (TASK-082), then the passed app, then
            // common user installs.
            privateRuntimeAppURL.appendingPathComponent("Contents/Resources/ollama"),
            appURL.appendingPathComponent("Contents/Resources/ollama"),
            URL(fileURLWithPath: "/usr/local/bin/ollama"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ollama"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func waitForServer() async {
        phase = .waitingForServer
        for _ in 0..<45 {  // up to 45 seconds
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await isServerReachable() {
                await Self.checkServerVersionCompatibility()
                return
            }
        }
        phase = .failed("The on-device AI runtime didn't start. Reopen Meeting Manager to retry, or switch to Claude in Settings.")
    }

    /// Query the running Ollama's /api/version and log a warning when the
    /// reported major.minor differs from `pinnedOllamaVersion`. Observability
    /// only — the app still talks to whatever's running. If an upstream
    /// breaking change ever ships, this warning is the breadcrumb that points
    /// at the version mismatch instead of presenting as a generic chat failure.
    private static func checkServerVersionCompatibility() async {
        let url = OllamaService.baseURL.appendingPathComponent("api/version")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        struct VersionResponse: Decodable { let version: String }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(VersionResponse.self, from: data) else {
            Logger.ai.info("Ollama /api/version not reachable — skipping compatibility check")
            return
        }
        let running = decoded.version
        let pinnedBare = String(pinnedOllamaVersion.dropFirst())  // "v0.24.0" → "0.24.0"
        let runningMajorMinor = running.split(separator: ".").prefix(2).joined(separator: ".")
        let pinnedMajorMinor = pinnedBare.split(separator: ".").prefix(2).joined(separator: ".")
        if runningMajorMinor == pinnedMajorMinor {
            Logger.ai.info("Ollama version OK: running \(running) (pinned \(pinnedBare))")
        } else {
            Logger.ai.warning("Ollama version mismatch: running \(running), pinned \(pinnedBare) — chat behavior may differ from tested baseline")
        }
    }

    private func pullModel(_ model: String) async {
        // Single-flight: if a pull of this tag is already running (foreground
        // OR background), don't start a second concurrent download of the same
        // model — the duplicate would race `phase` and the first finisher's
        // `defer` would remove the shared tag out from under the second pull.
        // Mirrors backgroundPullModel's guard.
        guard !inFlightPulls.contains(model) else { return }
        inFlightPulls.insert(model)
        defer { inFlightPulls.remove(model) }
        phase = .pullingModel(name: model, progress: 0)

        let url = OllamaService.baseURL.appendingPathComponent("api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600  // large models take time

        guard let body = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true]) else {
            phase = .failed("Could not encode pull request")
            return
        }
        request.httpBody = body

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                let status = json["status"] as? String ?? ""
                if status == "success" {
                    phase = .ready
                    return
                }
                let total = (json["total"] as? Double) ?? 0
                let completed = (json["completed"] as? Double) ?? 0
                if total > 0 {
                    phase = .pullingModel(name: model, progress: completed / total)
                }
            }
            phase = .ready
        } catch {
            phase = .failed("Model download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func isServerReachable() async -> Bool {
        let url = OllamaService.baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    private func fetchAvailableModels() async -> [String] {
        let url = OllamaService.baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) else {
            return []
        }
        return json.models.map { $0.name }
    }

    private func downloadFile(from url: URL, to dest: URL, onProgress: @escaping (Double) -> Void) async throws {
        // URLSession.download streams directly to disk — no byte-by-byte
        // buffering. Move the completed download into place.
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tempURL, to: dest)
        onProgress(1.0)   // app .zip download is a single move; report completion
    }

    private func runProcess(_ executable: String, args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: OllamaInstallerError.installFailed("Process exited with status \(p.terminationStatus)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func findInstalledOllama() -> URL? {
        let candidates = [
            // TASK-082 / ADR-016: our private headless runtime is preferred —
            // a relocated Ollama.app the user never sees in ~/Applications.
            privateRuntimeAppURL,
            // A user's own install is still honored as a fallback.
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Ollama.app"),
            URL(fileURLWithPath: "/Applications/Ollama.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Private runtime location (TASK-082 / ADR-016 A1)

    /// `~/Library/Application Support/MeetingManager/runtime/` — where the
    /// downloaded Ollama lives so it is NOT a user-facing app in
    /// ~/Applications (no Launchpad/menu-bar/updater presence).
    static var privateRuntimeDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MeetingManager/runtime", isDirectory: true)
    }

    /// The relocated `Ollama.app` inside the private runtime dir. Kept as a
    /// whole signed `.app` (not cherry-picked files) so the server finds its
    /// Metal runners by relative layout and the code signature stays valid.
    static var privateRuntimeAppURL: URL {
        privateRuntimeDir.appendingPathComponent("Ollama.app")
    }

    /// Models live under our control (TASK-082): `OLLAMA_MODELS` points here
    /// so they are not managed in `~/.ollama`. Existing users pull fresh.
    static var privateModelsDir: URL {
        privateRuntimeDir.appendingPathComponent("models", isDirectory: true)
    }
}

// MARK: - OllamaTagsResponse (shared decode type)

private struct OllamaTagsResponse: Decodable {
    struct ModelInfo: Decodable { let name: String }
    let models: [ModelInfo]
}
