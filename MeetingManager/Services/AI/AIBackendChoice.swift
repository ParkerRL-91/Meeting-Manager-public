import Foundation

/// The AI backend the app will use for generative work, resolved purely from
/// the user's single `aiProvider` selection (plus the stored key for the cloud
/// providers).
///
/// Single source of truth. Resolution used to be a copy-pasted predicate
/// (`useLocalLLM || (!hasClaudeKey && ollamaReachable)`) across five call sites,
/// which let the behaviour drift and silently fell back to Ollama whenever no
/// Claude key was present. Now exactly one provider is selected at a time
/// (`AIProvider`), so the active backend is a plain switch — no implicit
/// fallback. Gating AI-dependent task enqueues on "is the selected provider
/// usable" means a user with no AI configured no longer gets a failed summary
/// task — and a red error banner — after every meeting.
enum AIBackendChoice: Equatable, Sendable {
    case ollama(model: String)
    case claude(model: String)
    case gemini(model: String)
    case none

    var isAvailable: Bool { self != .none }

    /// Identifier persisted on generated artifacts (e.g. MeetingSummary.modelUsed).
    var modelIdentifier: String {
        switch self {
        case .ollama(let model): return "ollama/\(model)"
        case .claude(let model): return model
        case .gemini(let model): return "gemini/\(model)"
        case .none: return "none"
        }
    }
}

@MainActor
extension AppState {
    /// Resolve the active backend from the single `aiProvider` selection.
    /// Returns `.none` when the selected cloud provider has no key. The local
    /// case returns `.ollama` regardless of reachability (reachability is
    /// surfaced at the call site, matching the prior useLocalLLM behaviour).
    func resolveAIBackend(refreshOllama: Bool = false) async -> AIBackendChoice {
        switch settings.aiProvider {
        case .gemini:
            let hasKey = ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.geminiAPIKey)) ?? "")?.isEmpty == false
            return hasKey ? .gemini(model: settings.geminiModel) : .none
        case .claude:
            let hasKey = ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? "")?.isEmpty == false
            return hasKey ? .claude(model: settings.claudeModel) : .none
        case .local:
            if refreshOllama { await ollamaService.refreshStatus() }
            return .ollama(model: settings.ollamaModel)
        case .none:
            return .none
        }
    }

    /// Cheap synchronous check: is the selected provider usable?
    var isAIWorkConfigured: Bool {
        switch settings.aiProvider {
        case .gemini:
            return ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.geminiAPIKey)) ?? "")?.isEmpty == false
        case .claude:
            return ((try? KeychainHelper.loadString(forKey: KeychainHelper.Key.claudeAPIKey)) ?? "")?.isEmpty == false
        case .local:
            return true
        case .none:
            return false
        }
    }
}
