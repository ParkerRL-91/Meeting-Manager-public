import SwiftUI

/// Analytics dashboard. A filter bar (date range + participant) slices every
/// card: an overview stat row, your aggregate talk-share, a meetings-over-time
/// trend, a weekday distribution, top participants, and — when a meeting is
/// selected in the sidebar — its per-speaker talk time.
struct AnalyticsView: View {
    @Environment(AppState.self) private var appState

    // Filter state
    @State private var range: RangePreset = .last30
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()
    @State private var participant: String? = nil
    @State private var knownParticipants: [String] = []

    // Data
    @State private var overview: ParticipantAnalyticsService.Overview = .empty
    @State private var talkShare: ParticipantAnalyticsService.TalkShare = .empty
    @State private var trend: [ParticipantAnalyticsService.TrendBucket] = []
    @State private var weekday: [ParticipantAnalyticsService.WeekdayBucket] = []
    @State private var topParticipants: [ParticipantAnalyticsService.TopParticipant] = []
    @State private var talkTime: [ParticipantAnalyticsService.TalkTimePerSpeaker] = []
    @State private var talkTimeMeetingTitle: String?

    @State private var isLoading = true
    @State private var loadError: String?

    private let service = ParticipantAnalyticsService()

    // MARK: - Range presets

    enum RangePreset: String, CaseIterable, Identifiable {
        case thisWeek = "This week"
        case thisMonth = "This month"
        case last30 = "Last 30 days"
        case thisQuarter = "This quarter"
        case thisYear = "This year"
        case allTime = "All time"
        case custom = "Custom"

        var id: String { rawValue }
    }

    private var effectiveFilter: ParticipantAnalyticsService.AnalyticsFilter {
        let cal = ParticipantAnalyticsService.weekCalendar
        let now = Date()
        let bounds: (Date?, Date?)
        switch range {
        case .thisWeek:
            bounds = (cal.dateInterval(of: .weekOfYear, for: now)?.start, now)
        case .thisMonth:
            bounds = (cal.dateInterval(of: .month, for: now)?.start, now)
        case .last30:
            bounds = (cal.date(byAdding: .day, value: -30, to: now), now)
        case .thisQuarter:
            bounds = (Self.startOfQuarter(now, cal), now)
        case .thisYear:
            bounds = (cal.dateInterval(of: .year, for: now)?.start, now)
        case .allTime:
            bounds = (nil, nil)
        case .custom:
            // Include the whole end day.
            bounds = (cal.startOfDay(for: customStart),
                      cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customEnd)))
        }
        return .init(start: bounds.0, end: bounds.1, participant: participant)
    }

    /// Labels in stored transcripts that count as the local user. There is no
    /// "mic" label after attribution — the user's cluster is rewritten to their
    /// resolved name/email — so we match on the signed-in email and macOS full
    /// name (plus the raw "mic"/"You" fallbacks).
    private var youIdentifiers: [String] {
        var ids = ["mic", "You"]
        if let email = appState.googleAuthManager.userEmail, !email.isEmpty { ids.append(email) }
        let full = NSFullUserName()
        if !full.isEmpty { ids.append(full) }
        return ids
    }

    /// Drives `.task(id:)` reloads — changes whenever any filter input or the
    /// sidebar selection changes.
    private var reloadKey: String {
        let f = effectiveFilter
        return [range.rawValue,
                f.start.map { "\($0.timeIntervalSince1970)" } ?? "-",
                f.end.map { "\($0.timeIntervalSince1970)" } ?? "-",
                participant ?? "-",
                appState.selectedMeetingId ?? "-"].joined(separator: "|")
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                filterBar

                if isLoading {
                    loadingState
                } else if let err = loadError {
                    errorState(err)
                } else if overview.totalMeetings == 0 {
                    emptyState
                } else {
                    overviewRow
                    if talkShare.youSeconds > 0 { talkShareCard }
                    trendCard
                    weekdayCard
                    topParticipantsCard
                    if !talkTime.isEmpty { talkTimeCard }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .task(id: reloadKey) { await load() }
        .task { await loadParticipants() }
    }

    // MARK: - Header + filter bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Analytics")
                .font(.largeTitle.bold())
                .foregroundStyle(Color.appTextPrimary)
            Text("Insights from your completed meetings, sliced by date and participant.")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(RangePreset.allCases) { preset in
                        Button {
                            range = preset
                        } label: {
                            HStack {
                                Text(preset.rawValue)
                                if range == preset { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    filterChip(systemImage: "calendar", text: range.rawValue)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    Button {
                        participant = nil
                    } label: {
                        HStack {
                            Text("All people")
                            if participant == nil { Image(systemName: "checkmark") }
                        }
                    }
                    if !knownParticipants.isEmpty {
                        Divider()
                        ForEach(knownParticipants, id: \.self) { name in
                            Button {
                                participant = name
                            } label: {
                                HStack {
                                    Text(name).lineLimit(1)
                                    if participant == name { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                } label: {
                    filterChip(systemImage: "person", text: participant ?? "All people")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if participant != nil || range != .last30 {
                    Button {
                        range = .last30
                        participant = nil
                    } label: {
                        Text("Reset")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            if range == .custom {
                HStack(spacing: 10) {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                        .labelsHidden()
                    Text("→").foregroundStyle(Color.appTextTertiary)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                        .labelsHidden()
                }
                .font(.caption)
            }
        }
    }

    private func filterChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption)
            Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .foregroundStyle(Color.appTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.appSurface)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.appSeparator, lineWidth: 1))
    }

    // MARK: - Overview row

    private var overviewRow: some View {
        let tiles: [(String, String, String)] = [
            ("\(overview.totalMeetings)", overview.totalMeetings == 1 ? "meeting" : "meetings", "calendar"),
            (formattedHours(overview.totalHours), "total hours", "clock"),
            ("\(Int(overview.avgMinutes.rounded()))", "avg minutes", "gauge.medium"),
            ("\(Int(overview.longestMinutes.rounded()))", "longest (min)", "arrow.up.right"),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            ForEach(tiles, id: \.0) { value, label, icon in
                StatTile(value: value, label: label, systemImage: icon)
            }
        }
    }

    // MARK: - Talk share

    private var talkShareCard: some View {
        AnalyticsCard(title: "Your talk share") {
            VStack(alignment: .leading, spacing: 10) {
                let you = talkShare.youFraction
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        Capsule().fill(Color.appAccent)
                            .frame(width: max(2, geo.size.width * CGFloat(you)))
                        Capsule().fill(Color.appSurfaceSecondary)
                    }
                }
                .frame(height: 14)
                HStack {
                    legendDot(Color.appAccent, "You \(pct(you))")
                    Spacer()
                    legendDot(Color.appSurfaceSecondary, "Others \(pct(1 - you))")
                }
                Text("Across \(talkShare.meetingsCounted) \(talkShare.meetingsCounted == 1 ? "meeting" : "meetings") with captured audio.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.monospacedDigit()).foregroundStyle(Color.appTextSecondary)
        }
    }

    // MARK: - Trend

    private var trendCard: some View {
        AnalyticsCard(title: "Meetings over time") {
            if trend.isEmpty {
                Text("No meetings in this range.")
                    .font(.subheadline).foregroundStyle(Color.appTextSecondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    let maxCount = max(1, trend.map { $0.count }.max() ?? 1)
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(trend) { bucket in
                            Capsule()
                                .fill(Color.appAccent.opacity(bucket.count == 0 ? 0.18 : 0.85))
                                .frame(maxWidth: 24)
                                .frame(height: max(4, CGFloat(bucket.count) / CGFloat(maxCount) * 72))
                        }
                    }
                    .frame(height: 76, alignment: .bottom)
                    HStack {
                        Text(trend.first?.label ?? "").font(.caption2).foregroundStyle(Color.appTextTertiary)
                        Spacer()
                        Text("\(trend.reduce(0) { $0 + $1.count }) total").font(.caption2).foregroundStyle(Color.appTextTertiary)
                        Spacer()
                        Text(trend.last?.label ?? "").font(.caption2).foregroundStyle(Color.appTextTertiary)
                    }
                }
            }
        }
    }

    // MARK: - Weekday distribution

    private var weekdayCard: some View {
        AnalyticsCard(title: "By day of week") {
            let maxCount = max(1, weekday.map { $0.count }.max() ?? 1)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(weekday) { b in
                    VStack(spacing: 4) {
                        Text("\(b.count)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(Color.appTextTertiary)
                        Capsule()
                            .fill(Color.appAccent.opacity(b.count == 0 ? 0.18 : 0.85))
                            .frame(width: 18, height: max(4, CGFloat(b.count) / CGFloat(maxCount) * 64))
                        Text(b.label)
                            .font(.caption2).foregroundStyle(Color.appTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110, alignment: .bottom)
        }
    }

    // MARK: - Top participants

    private var topParticipantsCard: some View {
        AnalyticsCard(title: "Top participants") {
            if topParticipants.isEmpty {
                Text("No participants recorded in this range.")
                    .font(.subheadline).foregroundStyle(Color.appTextSecondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(topParticipants) { p in
                        HStack(spacing: 12) {
                            Text(p.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.appTextPrimary).lineLimit(1)
                            Spacer()
                            Text("\(p.meetingCount) \(p.meetingCount == 1 ? "meeting" : "meetings")")
                                .font(.caption.monospacedDigit()).foregroundStyle(Color.appTextSecondary)
                            Text("·").foregroundStyle(Color.appTextTertiary)
                            Text(Self.relativeShort(from: p.lastMet))
                                .font(.caption.monospacedDigit()).foregroundStyle(Color.appTextTertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Per-meeting talk time

    private var talkTimeCard: some View {
        AnalyticsCard(title: "Talk time (selected meeting)") {
            VStack(alignment: .leading, spacing: 10) {
                if let title = talkTimeMeetingTitle {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary).lineLimit(1)
                }
                let total = max(0.0001, talkTime.reduce(0) { $0 + $1.totalSeconds })
                ForEach(talkTime) { speaker in
                    TalkTimeBar(name: speaker.displayName, proportion: speaker.totalSeconds / total)
                }
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().controlSize(.regular); Spacer() }
            .padding(.vertical, 40)
    }

    private var emptyState: some View {
        AnalyticsCard(title: "Nothing here yet") {
            Text(participant == nil
                 ? "No completed meetings in this range. Try widening the date range."
                 : "No meetings with \(participant!) in this range.")
                .font(.subheadline).foregroundStyle(Color.appTextSecondary)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn't load analytics").font(.headline).foregroundStyle(Color.appTextPrimary)
            Text(message).font(.subheadline).foregroundStyle(Color.appTextSecondary)
            Button("Retry") { Task { await load() } }.buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Loaders

    private func load() async {
        isLoading = true
        loadError = nil
        let filter = effectiveFilter
        do {
            async let ov = service.overview(filter)
            async let ts = service.talkShare(filter, youIdentifiers: youIdentifiers)
            async let tr = service.trend(filter)
            async let wd = service.weekdayDistribution(filter)
            async let tp = service.topParticipants(filter)
            let (o, t, r, w, p) = try await (ov, ts, tr, wd, tp)
            overview = o; talkShare = t; trend = r; weekday = w; topParticipants = p

            if let meetingId = appState.selectedMeetingId,
               let meeting = appState.meetings.first(where: { $0.id == meetingId }) {
                talkTime = try await service.talkTime(forMeeting: meetingId, participants: meeting.participantList)
                talkTimeMeetingTitle = meeting.title
            } else {
                talkTime = []; talkTimeMeetingTitle = nil
            }
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func loadParticipants() async {
        knownParticipants = (try? await service.knownParticipants()) ?? []
    }

    // MARK: - Formatting

    private func formattedHours(_ hours: Double) -> String {
        if hours == 0 { return "0" }
        if hours < 10 { return String(format: "%.1f", hours) }
        return String(Int(hours.rounded()))
    }

    private func pct(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    private static func startOfQuarter(_ date: Date, _ cal: Calendar) -> Date? {
        let month = cal.component(.month, from: date)
        let quarterStartMonth = ((month - 1) / 3) * 3 + 1
        var comps = cal.dateComponents([.year], from: date)
        comps.month = quarterStartMonth
        comps.day = 1
        return cal.date(from: comps)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relativeShort(from date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Stat tile

private struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption).foregroundStyle(Color.appAccent)
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(Color.appTextPrimary)
            Text(label)
                .font(.caption).foregroundStyle(Color.appTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Card chrome

private struct AnalyticsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(Color.appTextTertiary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Talk time bar

private struct TalkTimeBar: View {
    let name: String
    let proportion: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.subheadline).foregroundStyle(Color.appTextPrimary)
                .frame(width: 80, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.appSurfaceSecondary)
                    Capsule().fill(Color.appAccent)
                        .frame(width: max(2, geo.size.width * CGFloat(proportion)))
                }
            }
            .frame(height: 10)
            Text("\(Int((proportion * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
