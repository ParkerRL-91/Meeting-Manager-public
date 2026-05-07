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

    /// One-shot check: re-pull any missing tier model if the user is on
    /// `auto`. No-op when both tier models are already installed. Cheap
    /// enough to call on every launch via `verifyLocalModelsOnStartup`.
    func verifyAndPullMissing() async {
        guard await isServerReachable() else { return }
        let available = await fetchAvailableModels()
        let missingSmall   = !available.contains(OllamaService.smallTier)
        let missingDefault = !available.contains(OllamaService.defaultTier)
        if !missingSmall && !missingDefault { return }
        // Non-blocking: kick off the background fan-out. setupIfNeeded
        // already does small-foreground + default-background.
        await setupIfNeeded(model: "auto")
    }

    /// Background pull variant — pulls the given model without flipping the
    /// public `phase` state away from `.ready`. The user keeps the small
    /// tier productive while this runs.
    private func backgroundPullModel(_ model: String) async {
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

        // Download Ollama-darwin.zip from GitHub
        let downloadURL = URL(string: "https://github.com/ollama/ollama/releases/latest/download/Ollama-darwin.zip")!
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

        // Move to ~/Applications
        let appsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        let dest = appsDir.appendingPathComponent("Ollama.app")
        do {
            try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: ollamaApp, to: dest)
        } catch {
            phase = .failed("Could not move Ollama.app to ~/Applications: \(error.localizedDescription)")
            return nil
        }

        // Cleanup temp
        try? fm.removeItem(at: tempDir)

        ollamaAppURL = dest
        return dest
    }

    private func launch(appURL: URL) async {
        phase = .launching
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do {
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            // NSWorkspace might throw even on success on some macOS versions — check if running
            Logger.ai.info("NSWorkspace.openApplication result: \(error.localizedDescription)")
        }
    }

    private func waitForServer() async {
        phase = .waitingForServer
        for _ in 0..<45 {  // up to 45 seconds
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await isServerReachable() { return }
        }
        phase = .failed("Ollama server didn't start. Try opening Ollama from ~/Applications.")
    }

    private func pullModel(_ model: String) async {
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
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        let total = Double((response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Length")
            .flatMap { Int64($0) } ?? 0)

        // URLSession.download writes directly to disk — no byte-by-byte buffering.
        // Move the completed download to the destination.
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tempURL, to: dest)

        if total > 0 {
            onProgress(1.0)
        } else {
            onProgress(1.0)
        }
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
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Ollama.app"),
            URL(fileURLWithPath: "/Applications/Ollama.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - OllamaTagsResponse (shared decode type)

private struct OllamaTagsResponse: Decodable {
    struct ModelInfo: Decodable { let name: String }
    let models: [ModelInfo]
}
