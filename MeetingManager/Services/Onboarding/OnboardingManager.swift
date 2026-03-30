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

    /// Tracks the user's AI choice during onboarding so downstream steps can adapt.
    var aiChoice: AIChoice {
        didSet { UserDefaults.standard.set(aiChoice.rawValue, forKey: aiChoiceKey) }
    }

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case calendar = 2
        case aiChoice = 3
        case localModel = 4
        case prompts = 5
        case ready = 6

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Permissions"
            case .calendar: return "Calendar"
            case .aiChoice: return "AI Setup"
            case .localModel: return "Local Model"
            case .prompts: return "Prompts"
            case .ready: return "Ready"
            }
        }
    }

    enum AIChoice: String {
        case local
        case claude
        case none
    }

    init() {
        let savedStep = UserDefaults.standard.integer(forKey: stepKey)
        self.currentStep = OnboardingStep(rawValue: savedStep) ?? .welcome
        let savedChoice = UserDefaults.standard.string(forKey: aiChoiceKey) ?? "none"
        self.aiChoice = AIChoice(rawValue: savedChoice) ?? .none
    }

    /// Steps that should be displayed (localModel is conditional on aiChoice == .local,
    /// prompts only shown if AI is enabled).
    var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            if step == .localModel { return aiChoice == .local }
            if step == .prompts { return aiChoice != .none }
            return true
        }
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
        aiChoice = .none
    }
}
