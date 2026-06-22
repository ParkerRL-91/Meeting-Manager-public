import SwiftUI

/// Onboarding step that lets a new user choose how long recorded audio is kept.
/// Audio (WAV) files are by far the largest thing the app stores, so this is a
/// storage decision. Pre-selects "Forever" — deleting is explicit (opt-in); the
/// step's job is to disclose the option, not to push deletion.
struct AudioRetentionStepView: View {
    let onContinue: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    explanation
                    choice
                    tradeOffNote
                    buttons
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.appAccent)
                Text("Choose how long to keep meeting audio")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.appTextPrimary)
            }
            Text("Optional · You can change this anytime in Settings → Audio")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meeting Manager keeps the audio recording of every meeting so you can replay it and re-transcribe it later. These recordings are the largest thing the app stores and can grow to tens of gigabytes over months of use.")
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can have old recordings removed automatically after a set time, or keep them forever. Either way, the transcript, summary, notes, and action items for every meeting are always kept.")
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var choice: some View {
        Picker("Keep audio for", selection: Binding(
            get: { appState.settings.audioRetentionDays },
            set: { appState.settings.audioRetentionDays = $0 }
        )) {
            Text("Forever").tag(0)
            Text("30 days").tag(30)
            Text("60 days").tag(60)
            Text("90 days").tag(90)
            Text("180 days").tag(180)
            Text("1 year").tag(365)
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 280, alignment: .leading)
    }

    private var tradeOffNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.appAccent)
                .font(.title3)
            Text("When a recording is removed, you can no longer play it back or re-run speaker analysis for that meeting; everything else stays. Nothing is removed until you pick a time limit, and the first cleanup runs the next time the app starts.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.appAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var buttons: some View {
        HStack {
            Button("Skip for now") { onContinue() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appTextSecondary)
            Spacer()
            Button("Continue") { onContinue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.appAccent)
        }
        .padding(.top, 8)
    }
}
