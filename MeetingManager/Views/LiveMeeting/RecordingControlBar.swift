import SwiftUI
import Combine

/// Top bar displaying recording status, elapsed time, audio levels, and stop control.
struct RecordingControlBar: View {
    let meetingId: String
    @Environment(AppState.self) private var appState

    @State private var elapsedSeconds: Int = 0
    @State private var timer: AnyCancellable?

    var body: some View {
        HStack(spacing: 16) {
            // Pulsing recording indicator
            RecordingDot()

            Text("Recording")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)

            // Elapsed time
            Text(formattedElapsedTime)
                .font(.body.monospaced())
                .foregroundStyle(Color.appTextSecondary)

            Spacer()

            // Audio level meters
            AudioLevelIndicator(
                label: "\u{1F3A4}",
                level: appState.micLevel,
                color: .appAccent
            )

            AudioLevelIndicator(
                label: "\u{1F50A}",
                level: appState.systemLevel,
                color: .appSuccess
            )

            // Stop button
            Button(action: {
                appState.stopRecording()
            }) {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.appRecording)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Stop Recording")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appSurface)
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    // MARK: - Timer

    private var formattedElapsedTime: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startTimer() {
        updateElapsed()
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                updateElapsed()
            }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func updateElapsed() {
        guard let start = appState.activeMeeting?.startDate else {
            elapsedSeconds = 0
            return
        }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
    }
}

// MARK: - Recording Dot

/// A pulsing red dot that indicates active recording.
private struct RecordingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.appRecording)
            .frame(width: 10, height: 10)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Preview

// #Preview {
//     RecordingControlBar(meetingId: "preview-123")
//         .environment(AppState())
// }
