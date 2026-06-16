import Foundation
import IOKit.ps

/// When background-class queue work (history backfills, the weekly
/// digest, future gardener/glossary batches) is allowed to run
/// (TASK-055). Pure and unit-tested; the queue consults it at pop time
/// for background items only — the meeting pipeline never passes through
/// here, and a RUNNING task is never preempted.
enum BackgroundWorkPolicy {

    struct Inputs {
        var isRecording: Bool
        var minutesToNextMeeting: Int?     // nil = nothing scheduled
        var thermalState: ProcessInfo.ThermalState
        var onBattery: Bool
        var allowOnBattery: Bool           // user setting, default false
        var interactivePending: Bool       // broker FIFO non-empty (review M9)
        var localHour: Int                 // 0–23
        var deferredSinceHours: Double     // oldest deferral age (starvation cap)
    }

    enum Decision: Equatable {
        case run
        case deferFor(minutes: Int)
    }

    /// Starvation cap (review M4): after 24 h of deferrals the work runs
    /// in the next gap regardless of the soft preferences (battery and
    /// recording still block — those are hard).
    static let maxDeferHorizonHours: Double = 24

    static func decision(_ i: Inputs) -> Decision {
        // Hard blocks — never contend with capture, and never drain the
        // battery without opt-in. These are the ONLY hard blocks (see the
        // maxDeferHorizonHours contract); they hold even when starved.
        if i.isRecording { return .deferFor(minutes: 15) }
        if !i.allowOnBattery && i.onBattery { return .deferFor(minutes: 30) }

        let starved = i.deferredSinceHours >= maxDeferHorizonHours

        // Soft preferences — overridden once the starvation cap is hit.
        // interactivePending is SOFT, not hard (TASK-092): a broker that
        // latches pendingCount > 0 must never be able to defer background work
        // past the starvation cap, or the escape hatch below is unreachable.
        if !starved {
            if i.interactivePending { return .deferFor(minutes: 2) }
            if let mins = i.minutesToNextMeeting, mins <= 20 {
                return .deferFor(minutes: max(5, mins + 5))
            }
            switch i.thermalState {
            case .serious, .critical: return .deferFor(minutes: 20)
            case .fair, .nominal: break
            @unknown default: break
            }
        } else {
            // Even starved work shouldn't run during a meeting window.
            if let mins = i.minutesToNextMeeting, mins <= 5 {
                return .deferFor(minutes: 10)
            }
        }
        return .run
    }

    // MARK: - Power probe

    /// True when the Mac is on battery power. IOKit power-sources API;
    /// desktops (no battery) report false.
    static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = info[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSBatteryPowerValue
            }
        }
        return false
    }
}
