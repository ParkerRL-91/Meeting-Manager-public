import Foundation

/// Relationship-health signals (TASK-061): pure metrics over rows the
/// Person/Company pages already load — meeting dates and open action
/// items. No LLM, no storage. Deliberately phrased as neutral signals,
/// not alerts (plan risk note: false alarms erode trust), and gated on
/// real history so a new contact never flags.
enum RelationshipHealth {

    struct Signal: Equatable, Identifiable {
        enum Kind: String {
            case staleContact
            case cadenceDrop
            case agingItems
        }
        let kind: Kind
        let detail: String
        var id: String { kind.rawValue }

        var label: String {
            switch kind {
            case .staleContact: return "Quiet lately"
            case .cadenceDrop: return "Cadence down"
            case .agingItems: return "Items aging"
            }
        }
        var icon: String {
            switch kind {
            case .staleContact: return "moon.zzz"
            case .cadenceDrop: return "chart.line.downtrend.xyaxis"
            case .agingItems: return "hourglass.bottomhalf.filled"
            }
        }
    }

    /// History floor: cadence/recency math needs an established pattern.
    static let minMeetingsForCadence = 3
    /// An item with no due date counts as aging after this many days.
    static let agingFloorDays = 21.0

    static func signals(meetingDates: [Date],
                        openItems: [(extractedAt: Date, dueDate: Date?)],
                        now: Date = Date()) -> [Signal] {
        var out: [Signal] = []

        let past = meetingDates.filter { $0 <= now }.sorted()
        if past.count >= minMeetingsForCadence, let last = past.last {
            let day = 86_400.0
            let sinceLast = now.timeIntervalSince(last) / day

            // Typical gap = median of the last 10 consecutive gaps.
            let recentDates = past.suffix(10)
            let gaps = zip(recentDates, recentDates.dropFirst())
                .map { $1.timeIntervalSince($0) / day }
            let median = medianOf(gaps)

            if let median, sinceLast >= max(21, 2 * median) {
                out.append(Signal(
                    kind: .staleContact,
                    detail: "Last met \(Int(sinceLast)) days ago; the typical gap was \(Int(median.rounded())) days."))
            } else {
                // Cadence drop only when not already flagged as stale —
                // one quiet-signal per relationship, the specific one.
                let baseline = past.filter {
                    $0 >= now.addingTimeInterval(-90 * day) && $0 < now.addingTimeInterval(-30 * day)
                }.count
                let recent = past.filter { $0 >= now.addingTimeInterval(-30 * day) }.count
                let monthlyBaseline = Double(baseline) / 2.0
                if monthlyBaseline >= 1.0, Double(recent) <= monthlyBaseline * 0.5 {
                    out.append(Signal(
                        kind: .cadenceDrop,
                        detail: "\(recent) meeting\(recent == 1 ? "" : "s") in the last 30 days, down from about \(Int(monthlyBaseline.rounded())) per month before."))
                }
            }
        }

        if past.count >= 2 {
            let day = 86_400.0
            let aging = openItems.filter { item in
                if let due = item.dueDate { return due < now }
                return now.timeIntervalSince(item.extractedAt) / day >= agingFloorDays
            }
            if !aging.isEmpty {
                let oldest = aging.map { now.timeIntervalSince($0.extractedAt) / day }.max() ?? 0
                out.append(Signal(
                    kind: .agingItems,
                    detail: "\(aging.count) open item\(aging.count == 1 ? "" : "s") past due or older than \(Int(agingFloorDays)) days; the oldest is \(Int(oldest)) days old."))
            }
        }

        return out
    }

    static func medianOf(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
