import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class ShareService {
    /// Opens native macOS share sheet for text content
    static func share(_ content: String, from view: NSView? = nil) {
        #if canImport(AppKit)
        let picker = NSSharingServicePicker(items: [content])
        if let view = view {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
        #endif
    }

    /// Copies text to clipboard
    static func copyToClipboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
