import Foundation

@Observable
@MainActor
final class OnboardingManager {
    private let completedKey = "onboardingCompleted"
    private let stepKey = "onboardingCurrentStep"
    private let aiChoiceKey = "onboardingAIChoice"

    var isCompleted: Bool = UserDefaults.standard.bool(forKey: "onboardingCompleted") {
        didSet { UserDefaults.standard.set(isCompleted, forKey: completedKey) }
    }

    var currentStep: OnboardingStep {
        didSet { UserDefaults.standard.set(currentStep.rawValue, forKey: stepKey) }
    }

    /// Tracks the user's AI choice. Defaults to `.local` (Ollama) — power users can
    /// switch to Claude in Settings → AI. Persisted for downstream consumers that
    /// still read this value, even though onboarding no longer prompts for it.
    var aiChoice: AIChoice {
        didSet { UserDefaults.standard.set(aiChoice.rawValue, forKey: aiChoiceKey) }
    }

    /// Onboarding flow. P2-T01 reduced this and moved AI choice / prompts to
    /// Settings; the on-device model step was re-added (ADR-016 / TASK-082 —
    /// it captures the model choice; the pull happens via the startup verify).
    /// Raw values are legacy-pinned — `init()` maps persisted indices onto
    /// them — so `.localModel` is appended as 4 and the display order is set
    /// explicitly in `visibleSteps`, not by raw value.
    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case calendar = 1
        case knowledgeBase = 2
        case ready = 3
        case localModel = 4
        case audioRetention = 5
        // Appended (legacy rawValues 0–4 are persisted); placement in the flow
        // is governed by `visibleSteps`, not the raw value.
        case storage = 6

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .calendar: return "Calendar"
            case .knowledgeBase: return "Knowledge Base"
            case .ready: return "Ready"
            case .localModel: return "On-Device AI"
            case .audioRetention: return "Audio"
            case .storage: return "Recordings"
            }
        }
    }

    enum AIChoice: String {
        case local
        case claude
        case gemini
        case none
    }

    init() {
        let savedStep = UserDefaults.standard.integer(forKey: stepKey)
        // Map legacy persisted step indices (0–6) onto the new 3-step flow so
        // a user mid-onboarding from a previous build doesn't land on an
        // invalid case.
        self.currentStep = OnboardingStep(rawValue: savedStep) ?? .welcome
        let savedChoice = UserDefaults.standard.string(forKey: aiChoiceKey) ?? "local"
        self.aiChoice = AIChoice(rawValue: savedChoice) ?? .local
    }

    /// Display order — the single source of truth for navigation and the dot
    /// indicator. Explicit (not `allCases`) because `.localModel`'s raw value
    /// is legacy-pinned to 4 and must appear before `.ready`, not after it.
    /// `nextStep()/previousStep()` walk this array, so order here governs.
    var visibleSteps: [OnboardingStep] {
        [.welcome, .storage, .calendar, .localModel, .audioRetention, .knowledgeBase, .ready]
    }

    func nextStep() {
        let visible = visibleSteps
        guard let currentIndex = visible.firstIndex(of: currentStep),
              currentIndex + 1 < visible.count else { return }
        currentStep = visible[currentIndex + 1]
    }

    func previousStep() {
        let visible = visibleSteps
        guard let currentIndex = visible.firstIndex(of: currentStep),
              currentIndex > 0 else { return }
        currentStep = visible[currentIndex - 1]
    }

    func complete() {
        isCompleted = true
        UserDefaults.standard.removeObject(forKey: stepKey)
        UserDefaults.standard.removeObject(forKey: aiChoiceKey)
    }

    /// Reset onboarding for testing purposes.
    func reset() {
        isCompleted = false
        currentStep = .welcome
        aiChoice = .local
    }
}
