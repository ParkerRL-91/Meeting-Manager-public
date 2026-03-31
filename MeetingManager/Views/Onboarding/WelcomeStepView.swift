import SwiftUI

struct WelcomeStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 72))
                .foregroundStyle(Color.appAccent)

            Text("Meeting Manager")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Capture, transcribe, and summarize your meetings with AI")
                .font(.title3)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()

            Button(action: onNext) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: 260)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)

            Spacer()
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// #Preview {
//     WelcomeStepView(onNext: {})
//         .frame(width: 600, height: 500)
//         .background(Color.appBackground)
//         .preferredColorScheme(.dark)
// }
