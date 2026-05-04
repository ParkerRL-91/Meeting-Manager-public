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
        // Upcoming reminders auto-dismiss after 30s; switch offers persist
        // until the user acts on them or AppState clears the offer.
        if mode == .upcoming {
            autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        window?.orderOut(nil)
    }
}
