import Foundation
import os

/// FIFO for USER-INITIATED local-AI generations contending with a busy
/// backend (TASK-071). The task-queue governor (TASK-055) keeps
/// background work out of the way; this broker makes interactive waits
/// VISIBLE and delivers results when the model frees up, instead of the
/// dead spinner the chat and daily brief used to show.
///
/// Busy detection is the OllamaService chokepoint counter — every local
/// generation and embedding passes through it (review B2), so prep
/// enrichment, queue handlers, catch-me-up, and other chat turns are all
/// seen, with a user-facing label of what's running.
@MainActor
final class InteractiveAIBroker {

    struct Entry: Identifiable {
        let id: UUID
        let label: String
        let enqueuedAt: Date
        /// The generation itself. Runs only when the backend is free.
        let work: () async -> Void
    }

    /// Wait-only ceiling (review m8): an entry that WAITED this long
    /// without starting fails visibly; once started, a generation runs to
    /// completion regardless.
    static let maxWaitMinutes: Double = 10

    /// Cadence of the self-heal sweep (TASK-092). Must be < maxWaitMinutes so
    /// expiry stays bounded; the sweep is a pure in-memory array filter (no
    /// I/O), so 60 s is negligible even in an app that idles for hours.
    private static let expirySweepSeconds: TimeInterval = 60

    private let logger = Logger(subsystem: "com.meetingmanager.app", category: "AIBroker")
    private let ollama: OllamaService
    private var queue: [Entry] = []
    private var draining = false
    /// Runs only while the queue is non-empty (TASK-092).
    private var expiryTimer: Timer?

    /// Called when an entry times out before starting — the owner updates
    /// its UI (e.g. replaces the chat placeholder with a retry message).
    var onTimeout: ((UUID) -> Void)?

    init(ollama: OllamaService) {
        self.ollama = ollama
    }

    var pendingCount: Int { queue.count }
    /// Labels of queued entries, for the Activities list (TASK-073).
    var waitingLabels: [String] { queue.map(\.label) }
    var isBlocked: Bool { ollama.inFlightCount > 0 }

    /// What the user-facing "waiting" message should name as the blocker.
    var blockedLabel: String? { ollama.inFlightLabel }

    /// Run now when free, otherwise queue. Returns true when queued (the
    /// caller shows its waiting state).
    @discardableResult
    func submit(id: UUID = UUID(), label: String, work: @escaping () async -> Void) -> Bool {
        if !isBlocked && queue.isEmpty {
            Task { [weak self] in
                await work()
                self?.drain()
            }
            return false
        }
        queue.append(Entry(id: id, label: label, enqueuedAt: Date(), work: work))
        startExpiryTimerIfNeeded()
        logger.info("Broker: queued '\(label)' behind \(self.ollama.inFlightLabel ?? "pending work") (\(self.queue.count) waiting)")
        return true
    }

    func cancel(id: UUID) {
        queue.removeAll { $0.id == id }
        if queue.isEmpty { stopExpiryTimer() }
    }

    /// Service the FIFO. Called on every chokepoint release and queue-idle
    /// edge, and by the self-heal timer (TASK-092); re-entrancy-guarded; one
    /// entry at a time (the backend is serial anyway). Expiry runs first and
    /// unconditionally — before the `draining`/`isBlocked` guard — so neither
    /// a busy backend nor an in-flight drain can keep a long-waited entry
    /// alive.
    func drain() {
        expireStaleEntries()
        guard !draining, !isBlocked, let next = queue.first else { return }
        queue.removeFirst()
        draining = true
        logger.info("Broker: running '\(next.label)' (\(self.queue.count) still waiting)")
        Task { [weak self] in
            await next.work()
            await MainActor.run {
                self?.draining = false
                self?.drain()
            }
        }
    }

    /// Remove entries that waited past `maxWaitMinutes` and notify their
    /// owners. Independent of `isBlocked`: the ceiling is about how long an
    /// entry WAITED without starting, not whether the backend is busy now.
    /// `asOf` is injectable for tests.
    func expireStaleEntries(asOf now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.maxWaitMinutes * 60)
        for expired in queue.filter({ $0.enqueuedAt < cutoff }) {
            logger.info("Broker: '\(expired.label)' timed out waiting")
            onTimeout?(expired.id)
        }
        queue.removeAll { $0.enqueuedAt < cutoff }
        if queue.isEmpty { stopExpiryTimer() }
    }

    // MARK: - Self-heal timer (TASK-092)

    /// The broker otherwise drains ONLY on external edges — a chokepoint
    /// release (`ollama.onAllWorkFinished`) or a queue-idle edge — and both
    /// are edge-triggered. An entry enqueued AFTER the last edge has no future
    /// trigger, so `drain()` (and the wait ceiling that lives inside it) would
    /// never run: `pendingCount` latches > 0, permanently asserting
    /// `interactivePending`, which defeats the background-work governor's
    /// starvation cap. This timer pokes `drain()` on a fixed cadence so stale
    /// entries expire on schedule. Runs only while work is queued.
    private func startExpiryTimerIfNeeded() {
        guard expiryTimer == nil else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: Self.expirySweepSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
    }

    private func stopExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
    }
}
