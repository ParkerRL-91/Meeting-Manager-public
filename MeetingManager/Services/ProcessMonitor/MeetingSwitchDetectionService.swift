import Foundation
import os

/// Watches the live detection signals *while a recording is active* and emits
/// `.meetingSwitchDetected` when the call the user is in appears to have
/// changed — a new Google Meet tab, a code change in the same tab, or a second
/// call surface (app launch / activation).
///
/// It only ever *suggests*: it never stops a recording. The consumer funnel
/// (present/accept/dismiss) is TASK-118.
///
/// ## Baseline-adoption rule (critical)
/// The engine NEVER diffs against the meeting's calendar title. For a
/// calendar/manual start the tab title ("Meet – abc-defg-hij") would never
/// match the calendar title ("Design Review") and every normal recording would
/// false-fire at ~90s. Instead the first stable (2-poll) observed title SET
/// after `arm()` becomes the baseline (seeded from the detector-started title
/// when the recording was detector-started). Only a stable NEW normalized title
/// outside that set emits — set membership, so an old tab left open can't mask
/// the new one.
///
/// Injected `now:` clock and `nearMeetings:` provider make it unit-testable
/// without a real clock or database (see `MeetingSwitchDetectionServiceTests`).
@MainActor
final class MeetingSwitchDetectionService {

    // MARK: - Tuning

    /// Ignore everything within this window of recording start. A normal
    /// recording's own tab title lands in the baseline well before this.
    static let armDelay: TimeInterval = 90

    /// A new title must survive this many consecutive non-empty polls before it
    /// emits (~20s at the 10s poll interval).
    static let confirmPolls = 2

    // MARK: - Injected dependencies

    private let now: @MainActor () -> Date
    private let nearMeetings: @MainActor (Date) async -> [Meeting]
    private let isEnabled: @MainActor () -> Bool
    private let isMemo: @MainActor () -> Bool
    private let normalizer = MeetingTitleNormalizer()

    init(
        now: @escaping @MainActor () -> Date = { Date() },
        isEnabled: @escaping @MainActor () -> Bool,
        isMemo: @escaping @MainActor () -> Bool,
        nearMeetings: @escaping @MainActor (Date) async -> [Meeting]
    ) {
        self.now = now
        self.isEnabled = isEnabled
        self.isMemo = isMemo
        self.nearMeetings = nearMeetings
    }

    // MARK: - Session state (reset on arm/disarm)

    private var armedAt: Date?

    /// The adopted baseline title set; `nil` until adoption completes.
    private var baselineTitles: Set<String>?
    /// Detector-start seed (provisional member of the baseline, unioned into
    /// the adopted set — a seed alone must NOT skip adoption, or a leftover
    /// tab from the previous meeting reads as a "switch" back to it).
    private var seedTitle: String?
    /// Baseline accumulates as the UNION of the first `confirmPolls + 1`
    /// non-empty polls (the observed set alternates when the AppleScript
    /// probe is throttled, so set-equality would never converge).
    private var baselineUnion: Set<String> = []
    private var baselinePollCount = 0

    /// The new (outside-baseline) title currently accumulating confirming
    /// polls. Tolerates one missed poll (2-of-last-3): a background-tab title
    /// is visible only to the throttled AppleScript probe and would otherwise
    /// flap out and reset forever.
    private var pendingNewTitle: String?
    private var pendingNewCount = 0
    private var pendingNewMisses = 0

    /// Normalized titles we've already emitted for this recording — never
    /// re-fire the same switch (the tab stays in the set for the rest of the call).
    private var firedTitles: Set<String> = []
    /// Bundle ids we've already emitted a second-call-app candidate for.
    private var firedAppBundles: Set<String> = []

    // MARK: - Suppression hooks (driven by the consumer funnel, TASK-118)

    private var suppressedUntil: Date?
    private var suppressedTitles: Set<String> = []

    /// Ignore all candidates until `date` (mirrors the departure-prompt cooldown).
    func suppress(until date: Date) { suppressedUntil = date }

    /// Never re-offer this normalized title for the rest of the recording
    /// (user chose "same meeting").
    func suppressTitle(_ normalized: String) { suppressedTitles.insert(normalized) }

    // MARK: - Lifecycle

    /// Begin watching. `detectorStartedTitle` seeds the baseline when the
    /// recording was started by the browser detector (its title is already the
    /// call the user is in). `startedAt` is the recording-start timestamp the
    /// arm delay is measured from.
    func arm(detectorStartedTitle: String?, startedAt: Date) {
        resetSession()
        armedAt = startedAt
        if let seed = detectorStartedTitle, let normalized = normalizer.normalize(seed) {
            // Provisional only — adoption still runs and the seed is unioned
            // into the adopted set. Skipping adoption on a seed made an old
            // tab left open from the PREVIOUS meeting look like a switch.
            seedTitle = normalized
            fileLog("armed — baseline will union detector seed '\(normalized)'")
        } else {
            fileLog("armed — awaiting observed title set for baseline")
        }
    }

    /// Stop watching and forget all session state. Called synchronously at the
    /// top of `stopRecording()` so no candidate can surface mid-teardown.
    func disarm() {
        guard armedAt != nil else { return }
        resetSession()
        fileLog("disarmed")
    }

    private func resetSession() {
        armedAt = nil
        baselineTitles = nil
        seedTitle = nil
        baselineUnion = []
        baselinePollCount = 0
        pendingNewTitle = nil
        pendingNewCount = 0
        pendingNewMisses = 0
        firedTitles = []
        firedAppBundles = []
        suppressedUntil = nil
        suppressedTitles = []
    }

    // MARK: - Signal A: in-call browser titles

    /// All titles matched as "in call" this poll (from `BrowserCallDetector`).
    func noteBrowserTitles(_ titles: [String]) {
        guard isActive() else { return }

        let normalized = Set(titles.compactMap { normalizer.normalize($0) })
        // nil/empty reads (minimized tab) neither trigger nor reset.
        guard !normalized.isEmpty else { return }

        // Adopt the baseline from the first stable 2-poll observed set.
        guard let baseline = baselineTitles else {
            adoptBaseline(from: normalized)
            return
        }

        let candidates = normalized
            .subtracting(baseline)
            .subtracting(firedTitles)
            .subtracting(suppressedTitles)

        if let pending = pendingNewTitle, !candidates.contains(pending) {
            // The pending title flapped out of this (non-empty) poll. Tolerate
            // ONE miss — a background-tab title is visible only to the
            // throttled AppleScript probe (every 3rd poll) — then reset.
            pendingNewMisses += 1
            if pendingNewMisses >= 2 {
                pendingNewTitle = nil
                pendingNewCount = 0
                pendingNewMisses = 0
            }
            return
        }

        guard let candidate = pendingNewTitle ?? candidates.sorted().first else { return }

        if candidate == pendingNewTitle {
            pendingNewCount += 1
            pendingNewMisses = 0
        } else {
            pendingNewTitle = candidate
            pendingNewCount = 1
            pendingNewMisses = 0
        }

        guard pendingNewCount >= Self.confirmPolls, armDelayElapsed() else { return }

        let display = titles.first(where: { normalizer.normalize($0) == candidate }) ?? candidate
        firedTitles.insert(candidate)
        pendingNewTitle = nil
        pendingNewCount = 0
        pendingNewMisses = 0
        Task { await self.emit(detectedTitle: display, normalizedTitle: candidate,
                               sourceSignal: "browserTitleChange", bundleIdentifier: nil) }
    }

    /// Baseline = union of the first `confirmPolls + 1` non-empty polls (plus
    /// any detector seed). Union, not set-equality: with the AppleScript probe
    /// throttled the observed set alternates between the foreground-only and
    /// full-tab views, so equal consecutive sets may never happen.
    private func adoptBaseline(from set: Set<String>) {
        baselineUnion.formUnion(set)
        baselinePollCount += 1
        if baselinePollCount >= Self.confirmPolls + 1 {
            if let seedTitle { baselineUnion.insert(seedTitle) }
            baselineTitles = baselineUnion
            fileLog("baseline adopted: \(baselineUnion.sorted())")
        }
    }

    // MARK: - Signal B: second call surface (opportunistic, medium-confidence)

    /// A call-app launch (`isActivation == false`) or activation
    /// (`isActivation == true`) for a bundle that isn't the recording's trigger.
    /// Fires at most once per bundle per recording.
    func noteCallAppEvent(bundleId: String, appName: String, isActivation: Bool) {
        guard isActive(), armDelayElapsed() else { return }
        guard !firedAppBundles.contains(bundleId) else { return }

        let normalized = normalizer.normalize(appName)
        if let normalized, suppressedTitles.contains(normalized) || firedTitles.contains(normalized) {
            return
        }

        firedAppBundles.insert(bundleId)
        if let normalized { firedTitles.insert(normalized) }
        fileLog("second call surface: \(appName) (\(bundleId), activation=\(isActivation))")
        Task {
            await self.emit(detectedTitle: appName, normalizedTitle: normalized ?? appName,
                            sourceSignal: "secondCallApp", bundleIdentifier: bundleId)
        }
    }

    // MARK: - Emission

    /// Calendar booster: a recordable meeting near now upgrades confidence
    /// medium→high and supplies `matchedMeetingId`.
    private func emit(detectedTitle: String, normalizedTitle: String,
                      sourceSignal: String, bundleIdentifier: String?) async {
        let recordable = await nearMeetings(now())
        // The recording may have stopped while we awaited — don't post a
        // suggestion into a teardown (the consumer also guards, this is hygiene).
        guard armedAt != nil else { return }
        let matched = recordable.first

        var userInfo: [String: String] = [
            "detectedTitle": detectedTitle,
            "normalizedTitle": normalizedTitle,
            "sourceSignal": sourceSignal,
            "confidence": matched != nil ? "high" : "medium",
        ]
        if let matched { userInfo["matchedMeetingId"] = matched.id }
        if let bundleIdentifier { userInfo["bundleIdentifier"] = bundleIdentifier }

        fileLog("EMIT \(sourceSignal) '\(detectedTitle)' confidence=\(userInfo["confidence"] ?? "?") matched=\(matched?.id ?? "none")")
        NotificationCenter.default.post(name: .meetingSwitchDetected, object: self, userInfo: userInfo)
    }

    // MARK: - Gates

    private func isActive() -> Bool {
        guard armedAt != nil, isEnabled(), !isMemo() else { return false }
        if let until = suppressedUntil, until > now() { return false }
        return true
    }

    private func armDelayElapsed() -> Bool {
        guard let armedAt else { return false }
        return now().timeIntervalSince(armedAt) >= Self.armDelay
    }

    private func fileLog(_ message: String) {
        AppFileLogger.shared.log("SwitchDetection: \(message)")
    }
}
