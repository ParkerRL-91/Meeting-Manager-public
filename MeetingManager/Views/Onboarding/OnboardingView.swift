import SwiftUI

struct OnboardingView: View {
    @Bindable var onboardingManager: OnboardingManager

    private var steps: [OnboardingManager.OnboardingStep] {
        OnboardingManager.OnboardingStep.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch onboardingManager.currentStep {
                case .welcome:
                    WelcomeStepView(onNext: onboardingManager.nextStep)
                case .permissions:
                    PermissionsStepView()
                case .setup:
                    SetupStepView()
                case .ready:
                    ReadyStepView(onComplete: onboardingManager.complete)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: onboardingManager.currentStep)

            // Bottom bar: navigation + dots
            bottomBar
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Back button
            if onboardingManager.currentStep != .welcome {
                Button(action: onboardingManager.previousStep) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appTextSecondary)
            } else {
                Spacer().frame(width: 80)
            }

            Spacer()

            // Dot indicator
            HStack(spacing: 8) {
                ForEach(steps, id: \.rawValue) { step in
                    Circle()
                        .fill(step == onboardingManager.currentStep ? Color.appAccent : Color.appTextTertiary)
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()

            // Next / Skip
            if onboardingManager.currentStep == .welcome || onboardingManager.currentStep == .ready {
                // Welcome uses its own Get Started button; Ready uses its own complete button
                Spacer().frame(width: 80)
            } else {
                Button(action: onboardingManager.nextStep) {
                    Label(nextButtonTitle, systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
            }
        }
    }

    private var nextButtonTitle: String {
        switch onboardingManager.currentStep {
        case .permissions: return "Next"
        case .setup: return "Skip"
        default: return "Next"
        }
    }
}

/// A label style that puts the icon after the text.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

// #Preview {
//     OnboardingView(onboardingManager: OnboardingManager())
//         .frame(width: 700, height: 550)
//         .preferredColorScheme(.dark)
// }
