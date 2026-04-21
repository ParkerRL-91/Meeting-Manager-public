import AppKit
import SwiftUI

struct CopyButton: View {
    let text: () -> String
    let label: String

    @State private var copied = false

    var body: some View {
        Button {
            ShareService.copyToClipboard(text())
            withAnimation {
                copied = true
            }
            // VoiceOver users don't see the "Copied!" label change — post an
            // announcement so they get immediate confirmation.
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Copied to clipboard",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    copied = false
                }
            }
        } label: {
            Label(
                copied ? "Copied!" : label,
                systemImage: copied ? "checkmark" : "doc.on.doc"
            )
            .font(.caption)
            .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(copied ? "Copied to clipboard" : label)
        .accessibilityHint("Copies the text to the clipboard")
    }
}

/// A helper view that provides an anchor NSView for the macOS share sheet picker.
struct ShareButton: NSViewRepresentable {
    let content: () -> String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.image = NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: "Share")
        button.bezelStyle = .toolbar
        button.target = context.coordinator
        button.action = #selector(Coordinator.showShareSheet(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.content = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    class Coordinator: NSObject {
        var content: () -> String

        init(content: @escaping () -> String) {
            self.content = content
        }

        @objc func showShareSheet(_ sender: NSButton) {
            let text = content()
            let picker = NSSharingServicePicker(items: [text])
            picker.show(relativeTo: .zero, of: sender, preferredEdge: .minY)
        }
    }
}
