import AppKit
import SwiftUI

/// Floating NSPanel that shows a pre-meeting HUD card. Uses .nonactivating so it
/// never steals focus from whatever app the user is working in.
@MainActor
final class MeetingReminderWindowController: NSWindowController {

    private var autoDismissTimer: Timer?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false   // shadow baked into the SwiftUI view
        panel.isMovableByWindowBackground = true
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(meeting: Meeting, mode: MeetingReminderMode = .upcoming) {
        guard let panel = window else { return }

        let view = MeetingReminderView(meeting: meeting, mode: mode) { [weak self] in
            // Switch-mode dismiss is treated as "user explicitly dismissed
            // this offer" so AppState won't re-show it for the same meeting.
            if mode == .switch {
                NotificationCenter.default.post(
                    name: .meetingSwitchDismiss,
                    object: nil,
                    userInfo: ["dismissedByUser": meeting.id]
                )
            }
            self?.dismiss()
        }
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        // Size to fit the SwiftUI content
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let width  = max(460, size.width)
        let height = max(72,  size.height)

        // Position: top-right of the main screen, just below the menu bar
        let margin: CGFloat = 16
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(
                x: visible.maxX - width - margin,
                y: visible.maxY - height - margin,
                width: width,
                height: height
            ), display: false)
        }

        panel.orderFront(nil)

        autoDismissTimer?.invalidate()
        // Upcoming reminders persist until the meeting is *clearly* underway
        // (scheduled start + 60 s) OR the user acts on the button. Earlier
        // versions auto-dismissed after 30 s, which routinely vanished
        // before the user noticed it. Now: visible until +1 min after the
        // scheduled start, totaling roughly 3 minutes when the HUD fires
        // 2 min before start. Switch offers still persist indefinitely
        // until the user acts or AppState clears the offer.
        if mode == .upcoming {
            let dismissAt = (meeting.scheduledStartDate ?? Date())
                .addingTimeInterval(60)
            let interval = dismissAt.timeIntervalSinceNow
            if interval > 0 {
                autoDismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                }
            } else {
                // Meeting started > 1 min ago by the time the HUD got
                // requested — dismiss immediately, the moment has passed.
                dismiss()
            }
        }
    }

    /// Floating card for a high-confidence unified switch suggestion (TASK-118).
    /// Persists until the user acts or AppState clears/demotes the offer.
    func show(suggestion: AppState.SwitchSuggestion) {
        guard let panel = window else { return }

        let currentTitle = AppState.shared?.activeMeeting?.title ?? "current meeting"
        let view = SwitchSuggestionView(suggestion: suggestion, currentTitle: currentTitle) { [weak self] in
            AppState.shared?.dismissSwitchSuggestion(byUser: true)
            self?.dismiss()
        }
        // Cap the width — a long tab title would otherwise stretch the panel
        // across the screen (visible over a screen share). Text inside
        // truncates/wraps within the fixed width.
        let hosting = NSHostingView(rootView: view.frame(width: 520))
        panel.contentView = hosting

        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let width: CGFloat = 520
        let height = max(72, size.height)

        let margin: CGFloat = 16
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(
                x: visible.maxX - width - margin,
                y: visible.maxY - height - margin,
                width: width,
                height: height
            ), display: false)
        }

        panel.orderFront(nil)
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        window?.orderOut(nil)
    }
}
