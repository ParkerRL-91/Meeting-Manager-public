import SwiftUI
import Combine

/// A relative-time label that updates at a sensible cadence — not every second.
///
/// Tick policy:
/// - 0–5s        → "Just now"
/// - 5–60s       → "Less than a minute ago"
/// - 1–59 min    → "X min ago"          (re-renders once per minute)
/// - 1–23 hr     → "X hr ago"           (re-renders once per hour)
/// - ≥ 1 day     → "X days ago" / "Yesterday"  (re-renders once per day)
///
/// Background: SwiftUI's built-in `Text(date, style: .relative)` ticks every
/// second, which makes the Activity panel feel jittery and CPU-noisy when many
/// completed jobs are shown at once. This view recomputes a bucketed string on
/// a single shared cadence and renders only when the bucket actually changes.
struct RelativeTimestampLabel: View {
    let date: Date
    /// Optional prefix word (e.g. "Completed").
    var prefix: String?

    @State private var displayString: String = ""

    /// One shared 60-second tick is plenty: minute resolution is the densest
    /// bucket we care about. Hour and day buckets just no-op.
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(displayString)
            .onAppear { recompute() }
            .onReceive(timer) { _ in recompute() }
            .onChange(of: date) { _, _ in recompute() }
    }

    private func recompute() {
        let elapsed = -date.timeIntervalSinceNow
        let core = Self.bucketedString(forElapsed: elapsed)
        displayString = prefix.map { "\($0) \(core)" } ?? core
    }

    /// Pure formatting — exposed `static` so previews and tests can hit it
    /// without instantiating the timer-driven view.
    static func bucketedString(forElapsed elapsed: TimeInterval) -> String {
        // Future timestamps (clock skew, race conditions) — treat as "Just now".
        guard elapsed >= 0 else { return "just now" }

        if elapsed < 5 { return "just now" }
        if elapsed < 60 { return "less than a minute ago" }

        let minutes = Int(elapsed / 60)
        if minutes < 60 {
            return minutes == 1 ? "1 min ago" : "\(minutes) min ago"
        }

        let hours = Int(elapsed / 3600)
        if hours < 24 {
            return hours == 1 ? "1 hr ago" : "\(hours) hr ago"
        }

        let days = Int(elapsed / 86_400)
        if days == 1 { return "yesterday" }
        return "\(days) days ago"
    }
}
