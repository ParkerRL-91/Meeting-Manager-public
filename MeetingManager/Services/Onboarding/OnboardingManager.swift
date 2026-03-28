import Foundation

@Observable
@MainActor
final class OnboardingManager {
    private let completedKey = "onboardingCompleted"

    var isCompleted: Bool = UserDefaults.standard.bool(forKey: "onboardingCompleted") {
        didSet { UserDefaults.standard.set(isCompleted, forKey: completedKey) }
    }

    var currentStep: OnboardingStep = .welcome

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case setup = 2
        case ready = 3

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Permissions"
            case .setup: return "Setup"
            case .ready: return "Ready"
            }
        }
    }

    func nextStep() {
        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            currentStep = next
        }
    }

    func previousStep() {
        if let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) {
            currentStep = prev
        }
    }

    func complete() {
        isCompleted = true
    }
}
