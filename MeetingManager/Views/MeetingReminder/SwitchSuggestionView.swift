import SwiftUI
import AppKit

/// Shared copy for the unified switch suggestion (TASK-118). Every surface —
/// floating window, in-app banner, menu bar popover, right-click menu — uses
/// the same accept/decline labels and the same stops-current caption so the
/// action reads identically wherever the user meets it.
enum SwitchSuggestionCopy {
    static let acceptLabel = "Switch & Record"

    static func declineLabel(for origin: AppState.SwitchSuggestion.Origin) -> String {
        // The user may have opened a call app for an unrelated reason — don't
        // make them assert a fact ("Same meeting") that isn't true.
        origin == .detectedApp ? "Keep recording" : "Same meeting"
    }

    /// Minutes since the switch was first detected, floored to at least 1 so the
    /// drift note never reads "last ~0 min".
    static func minutesSince(_ firedAt: Date) -> Int {
        max(1, Int(Date().timeIntervalSince(firedAt) / 60))
    }

    /// "stops 'A', starts a new one · last ~N min stay in 'A'".
    static func acceptCaption(currentTitle: String, firedAt: Date) -> String {
        let n = minutesSince(firedAt)
        return "stops \u{201C}\(currentTitle)\u{201D}, starts a new one · last ~\(n) min stay in \u{201C}\(currentTitle)\u{201D}"
    }

    static func signalCaption(for suggestion: AppState.SwitchSuggestion) -> String {
        switch suggestion.origin {
        case .calendar:      return "A calendar meeting is starting now."
        case .detectedTitle: return "The live call title changed."
        case .detectedApp:   return "A second call app opened."
        }
    }
}

/// Floating NSPanel content for a high-confidence switch suggestion. Mirrors
/// `MeetingReminderView` `.switch` visuals (dark card, orange accent) but reads
/// the unified suggestion and routes actions through AppState.
struct SwitchSuggestionView: View {
    let suggestion: AppState.SwitchSuggestion
    let currentTitle: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 4)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12, bottomLeadingRadius: 12,
                        bottomTrailingRadius: 0, topTrailingRadius: 0
                    )
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Switch to new meeting")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(suggestion.detectedTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(SwitchSuggestionCopy.acceptCaption(currentTitle: currentTitle, firedAt: suggestion.firedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                Button(action: {
                    AppState.shared?.acceptSwitchSuggestion()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.orange)
                        Text(SwitchSuggestionCopy.acceptLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(SwitchSuggestionCopy.acceptLabel). Stops \(currentTitle), starts \(suggestion.detectedTitle).")

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 36)

                Menu {
                    Button(SwitchSuggestionCopy.declineLabel(for: suggestion.origin)) { onDismiss() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 32, height: 52)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(SwitchSuggestionCopy.declineLabel(for: suggestion.origin))
            }
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.trailing, 12)
        }
        .frame(minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 0.96)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 6)
        .padding(6)
    }
}

/// Slim in-app banner shown above `RecordingStrip` in `LiveMeetingView`.
/// `DepartureConfirmBar` styling (orange). Thin — all logic lives in AppState.
struct SwitchSuggestionInlineBanner: View {
    let suggestion: AppState.SwitchSuggestion
    @Environment(AppState.self) private var appState

    private var currentTitle: String { appState.activeMeeting?.title ?? "this meeting" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New meeting detected: \u{201C}\(suggestion.detectedTitle)\u{201D}.")
                .font(.caption)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(SwitchSuggestionCopy.acceptCaption(currentTitle: currentTitle, firedAt: suggestion.firedAt))
                .font(.caption2)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(SwitchSuggestionCopy.acceptLabel) {
                    appState.acceptSwitchSuggestion()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
                .accessibilityLabel("\(SwitchSuggestionCopy.acceptLabel). Stops \(currentTitle), starts \(suggestion.detectedTitle).")

                Button(SwitchSuggestionCopy.declineLabel(for: suggestion.origin)) {
                    appState.dismissSwitchSuggestion(byUser: true)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(SwitchSuggestionCopy.declineLabel(for: suggestion.origin))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }
}
