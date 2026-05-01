import SwiftUI

struct OnboardingView: View {
    @Bindable var onboardingManager: OnboardingManager
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            // P2-T01: 3-step onboarding. AI choice / local model / prompts steps
            // were removed — defaults to Ollama local; users can switch in
            // Settings → AI. Model download moves to a background banner on Home.
            Group {
                switch onboardingManager.currentStep {
                case .welcome:
                    WelcomeStepView(onNext: onboardingManager.nextStep)
                case .calendar:
                    CalendarStepView(onAdvance: onboardingManager.nextStep)
                case .knowledgeBase:
                    KnowledgeBaseStepView(onSkip: onboardingManager.nextStep)
                case .ready:
                    ReadyStepView(onComplete: onboardingManager.complete)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: onboardingManager.currentStep)

            // Bottom bar: navigation + dots
            bottomBar
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            // Persistent download progress bar at the very bottom
            if appState.isLoadingModel {
                downloadProgressBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isLoadingModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    // MARK: - Download Progress Bar

    private var downloadProgressBar: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("Downloading transcription model...")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

            ProgressView(value: appState.modelDownloadProgress)
                .progressViewStyle(.linear)
                .tint(Color.appAccent)
                .frame(maxWidth: 180)

            Text("\(Int(appState.modelDownloadProgress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.appTextSecondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.appAccent.opacity(0.08).background(Color.appSurface))
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
                ForEach(onboardingManager.visibleSteps, id: \.rawValue) { step in
                    Circle()
                        .fill(step == onboardingManager.currentStep ? Color.appAccent : Color.appTextTertiary)
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()

            // Next / Skip — welcome and ready own their CTAs; calendar +
            // knowledge-base steps offer a subtle "Next" link in the bar.
            switch onboardingManager.currentStep {
            case .welcome, .ready:
                Spacer().frame(width: 80)
            case .calendar, .knowledgeBase:
                Button(action: onboardingManager.nextStep) {
                    Label("Next", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
            }
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
