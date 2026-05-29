import Foundation

/// The AI backend the app will use for generative work, resolved from the
/// user's settings, stored Claude key, and Ollama reachability.
///
/// Single source of truth. This exact predicate used to be copy-pasted in five
/// places (summary, context brief, global text generator, meeting chat, action
/// items), which let the behaviour drift. Centralizing it also lets
/// AI-dependent task enqueues be gated on "is any backend actually usable," so
/// a user with no AI configured no longer gets a failed summary task — and a
/// red error banner — after every meeting.
enum AIBackendChoice: Equatable {
    case ollama(model: String)
    case claude(model: String)
    case none

    var isAvailable: Bool { self != .none }

    /// Identifier persisted on generated artifacts (e.g. MeetingSummary.modelUsed).
    var modelIdentifier: String {
        switch self {
        case .ollama(let model): return "ollama/\(model)"
        case .claude(let model): return model
        case .none: return "none"
        }
    }
}

@MainActor
extension AppState {
    /// Resolve the active backend. Pass `refreshOllama: true` from long-running
    /// task handlers (does a live reachability probe); leave it false for cheap
    /// UI checks that can rely on the last cached Ollama status.
    ///
    /// Semantics are identical to the old inline predicate:
    /// `useOllama = useLocalLLM || (!hasClaudeKey && ollamaReachable)`.
    func resolveAIBackend(refreshOllama: Bool = false) async -> AIBackendChoice {
        let hasClaudeKey = ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? "")?.isEmpty == false
        if refreshOllama { await ollamaService.refreshStatus() }
        let ollamaReachable = ollamaService.isReachable
        let useOllama = settings.useLocalLLM || (!hasClaudeKey && ollamaReachable)

        if useOllama {
            return .ollama(model: settings.ollamaModel)
        } else if hasClaudeKey {
            return .claude(model: settings.claudeModel)
        }
        return .none
    }

    /// Cheap synchronous check: is any AI backend configured at all? Used to
    /// gate auto-enqueue of AI-dependent tasks without a live network probe
    /// (relies on the last cached Ollama status). Equivalent to
    /// `resolveAIBackend().isAvailable` minus the refresh.
    var isAIWorkConfigured: Bool {
        let hasClaudeKey = ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? "")?.isEmpty == false
        return settings.useLocalLLM || hasClaudeKey || ollamaService.isReachable
    }
}
