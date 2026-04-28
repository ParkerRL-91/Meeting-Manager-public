import SwiftUI

/// Top-level analytics dashboard accessible from the sidebar. Shows four cards:
/// this-week stats, talk-time for the currently-selected meeting (if any),
/// top participants, and an 8-week meeting trend.
struct AnalyticsView: View {
    @Environment(AppState.self) private var appState

    @State private var weekly: ParticipantAnalyticsService.WeeklyStats?
    @State private var talkTime: [ParticipantAnalyticsService.TalkTimePerSpeaker] = []
    @State private var talkTimeMeetingTitle: String?
    @State private var topParticipants: [ParticipantAnalyticsService.TopParticipant] = []
    @State private var trend: [ParticipantAnalyticsService.MeetingTrendBucket] = []

    @State private var isLoading = true
    @State private var loadError: String?

    private let service = ParticipantAnalyticsService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if isLoading {
                    loadingState
                } else if let err = loadError {
                    errorState(err)
                } else {
                    weeklyCard
                    if !talkTime.isEmpty {
                        talkTimeCard
                    }
                    topParticipantsCard
                    trendCard
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .task(id: appState.selectedMeetingId) {
            await load()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Analytics")
                .font(.largeTitle.bold())
                .foregroundStyle(Color.appTextPrimary)
            Text("Insights from your recent meetings")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
        }
    }

    // MARK: - Cards

    private var weeklyCard: some View {
        AnalyticsCard(title: "This week") {
            // weeklyStats() always returns a non-nil struct (zeroed when no
            // meetings), so we additionally gate on count > 0 to actually surface
            // the empty state instead of a card full of zeros.
            if let w = weekly, w.count > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(formattedHours(w.totalHours))
                            .font(.title.bold().monospacedDigit())
                            .foregroundStyle(Color.appTextPrimary)
                        Text(w.totalHours == 1 ? "hour" : "hours")
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                        Text("·")
                            .foregroundStyle(Color.appTextTertiary)
                        Text("\(w.count) \(w.count == 1 ? "meeting" : "meetings")")
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Text("Avg \(Int(w.avgMinutes.rounded())) min")
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextTertiary)
                }
            } else {
                Text("No completed meetings this week.")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    private var talkTimeCard: some View {
        AnalyticsCard(title: "Talk time") {
            VStack(alignment: .leading, spacing: 10) {
                if let title = talkTimeMeetingTitle {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)
                }
                let total = max(0.0001, talkTime.reduce(0) { $0 + $1.totalSeconds })
                ForEach(talkTime) { speaker in
                    TalkTimeBar(
                        name: speaker.displayName,
                        proportion: speaker.totalSeconds / total
                    )
                }
            }
        }
    }

    private var topParticipantsCard: some View {
        AnalyticsCard(title: "Top participants") {
            if topParticipants.isEmpty {
                Text("No participants recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(topParticipants) { p in
                        HStack(spacing: 12) {
                            Text(p.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.appTextPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(p.meetingCount) \(p.meetingCount == 1 ? "meeting" : "meetings")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.appTextSecondary)
                            Text("·")
                                .foregroundStyle(Color.appTextTertiary)
                            Text(Self.relativeShort(from: p.lastMet))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.appTextTertiary)
                        }
                    }
                }
            }
        }
    }

    private var trendCard: some View {
        AnalyticsCard(title: "Trending") {
            VStack(alignment: .leading, spacing: 10) {
                let maxCount = max(1, trend.map { $0.count }.max() ?? 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(trend) { bucket in
                        VStack(spacing: 4) {
                            Capsule()
                                .fill(Color.appAccent.opacity(bucket.count == 0 ? 0.18 : 0.85))
                                .frame(width: 16, height: max(4, CGFloat(bucket.count) / CGFloat(maxCount) * 64))
                            Text("\(bucket.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.appTextTertiary)
                        }
                    }
                }
                .frame(height: 84, alignment: .bottom)
                HStack {
                    Text("\(trend.count) weeks ago")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                    Spacer()
                    Text("Today")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.regular)
            Spacer()
        }
        .padding(.vertical, 40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn't load analytics")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
            Button("Retry") {
                Task { await load() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Loader

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            async let weeklyTask = service.weeklyStats()
            async let topTask = service.topParticipants()
            async let trendTask = service.meetingTrend()

            let (w, top, tr) = try await (weeklyTask, topTask, trendTask)
            self.weekly = w
            self.topParticipants = top
            self.trend = tr

            // Talk time depends on the currently-selected meeting (if any).
            if let meetingId = appState.selectedMeetingId,
               let meeting = appState.meetings.first(where: { $0.id == meetingId }) {
                let participants = meeting.participantList
                let tt = try await service.talkTime(forMeeting: meetingId, participants: participants)
                self.talkTime = tt
                self.talkTimeMeetingTitle = meeting.title
            } else {
                self.talkTime = []
                self.talkTimeMeetingTitle = nil
            }

            self.isLoading = false
        } catch {
            self.loadError = error.localizedDescription
            self.isLoading = false
        }
    }

    // MARK: - Formatting

    private func formattedHours(_ hours: Double) -> String {
        if hours == 0 { return "0" }
        if hours < 10 {
            return String(format: "%.1f", hours)
        }
        return String(Int(hours.rounded()))
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
    let proportion: Double  // 0...1

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(Color.appTextPrimary)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.appSurfaceSecondary)
                    Capsule()
                        .fill(Color.appAccent)
                        .frame(width: max(2, geo.size.width * CGFloat(proportion)))
                }
            }
            .frame(height: 10)
            Text(percentString(proportion))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func percentString(_ p: Double) -> String {
        let pct = Int((p * 100).rounded())
        return "\(pct)%"
    }
}
