import SwiftUI

/// Dark-mode-first color palette designed for focused, calm meeting workflows.
/// All colors provide adaptive light/dark variants but are optimised for the dark appearance.
extension Color {

    // MARK: - Backgrounds

    /// Primary background. Dark: #1C1C1E, Light: #FFFFFF.
    static let background = Color("Background", bundle: nil)
        .self // replaced by programmatic init below

    /// Elevated surface (cards, panels). Dark: #2C2C2E, Light: #F2F2F7.
    static let surface = Color("Surface", bundle: nil)
        .self

    /// Subtle surface used for grouped content. Dark: #3A3A3C, Light: #E5E5EA.
    static let surfaceSecondary = Color("SurfaceSecondary", bundle: nil)
        .self

    // MARK: - Text

    /// Primary text color. Dark: white, Light: black.
    static let textPrimary = Color("TextPrimary", bundle: nil)
        .self

    /// Secondary / muted text color. Dark: #AEAEB2, Light: #8E8E93.
    static let textSecondary = Color("TextSecondary", bundle: nil)
        .self

    /// Tertiary / placeholder text. Dark: #636366, Light: #C7C7CC.
    static let textTertiary = Color("TextTertiary", bundle: nil)
        .self

    // MARK: - Accent Colors

    /// Main accent color (interactive elements, links). A vivid blue.
    static let accent = Color("Accent", bundle: nil)
        .self

    /// Recording indicator red.
    static let recording = Color("Recording", bundle: nil)
        .self

    /// Success / positive state green.
    static let success = Color("Success", bundle: nil)
        .self

    /// Warning amber.
    static let warning = Color("Warning", bundle: nil)
        .self

    // MARK: - Dividers & Borders

    /// Thin separator line. Dark: #48484A, Light: #D1D1D6.
    static let separator = Color("Separator", bundle: nil)
        .self
}

// MARK: - Programmatic Adaptive Colors

/// Use these when asset catalog colors are not yet set up. They produce the
/// same adaptive behaviour without requiring an `.xcassets` entry.
extension Color {

    // MARK: - Backgrounds (design system v2)
    // bg-1: main content pane
    static let appBackground = Color(light: .hex(0xFAFAFB), dark: .hex(0x131316))
    // bg-2: sidebar, title bar, resting card
    static let appSurface = Color(light: .hex(0xF4F4F6), dark: .hex(0x18181C))
    // bg-3: raised card, ghost-button bg, hover
    static let appSurfaceSecondary = Color(light: .hex(0xECECF0), dark: .hex(0x1F1F24))
    // bg-4: sidebar selected row, owner chip bg
    static let appSurfaceElevated = Color(light: .hex(0xE4E4EA), dark: .hex(0x26262C))
    // bg-5: active/pressed
    static let appSurfacePressed = Color(light: .hex(0xDCDCE4), dark: .hex(0x2E2E35))

    // MARK: - Text
    // fg-0: primary content
    static let appTextPrimary = Color(light: .hex(0x131316), dark: .hex(0xF4F4F6))
    // fg-1: secondary (sidebar nav labels)
    static let appTextSecondary = Color(light: .hex(0x3A3A3F), dark: .hex(0xD4D4D8))
    // fg-2: tertiary, labels, meta
    static let appTextTertiary = Color(light: .hex(0x6C6C75), dark: .hex(0x9A9AA3))
    // fg-3: muted (counts, timestamps, section labels)
    static let appTextMuted = Color(light: .hex(0x9A9AA3), dark: .hex(0x6C6C75))

    // MARK: - Accent (indigo-blue)
    // Active sidebar item text, links
    static let appAccentLight = Color(light: .hex(0x4F6CEF), dark: .hex(0x8EA7FF))
    // Active tab underline
    static let appAccentMid = Color(light: .hex(0x4F6CEF), dark: .hex(0x6B86F5))
    // Primary buttons, CTA
    static let appAccent = Color(light: .hex(0x4F6CEF), dark: .hex(0x4F6CEF))
    // Active sidebar row background
    static let appAccentSubtle = Color(light: .hex(0x4F6CEF, opacity: 0.10), dark: .hex(0x4F6CEF, opacity: 0.14))
    // TL;DR card border
    static let appAccentSubtleStrong = Color(light: .hex(0x4F6CEF, opacity: 0.16), dark: .hex(0x4F6CEF, opacity: 0.22))

    // MARK: - Semantic
    static let appSuccess = Color(light: .hex(0x22C55E), dark: .hex(0x4ADE80))
    static let appSuccessSubtle = Color(light: .hex(0x22C55E, opacity: 0.10), dark: .hex(0x22C55E, opacity: 0.14))
    static let appWarning = Color(light: .hex(0xD97706), dark: .hex(0xF5B942))
    static let appWarningSubtle = Color(light: .hex(0xF5B942, opacity: 0.10), dark: .hex(0xF5B942, opacity: 0.14))
    static let appRecording = Color(light: .hex(0xEF4444), dark: .hex(0xF97268))
    static let appRecordingSubtle = Color(light: .hex(0xEF4444, opacity: 0.08), dark: .hex(0xEF4444, opacity: 0.14))
    static let appViolet = Color(light: .hex(0x8B5CF6), dark: .hex(0xA78BFA))
    static let appVioletSubtle = Color(light: .hex(0xA78BFA, opacity: 0.10), dark: .hex(0xA78BFA, opacity: 0.14))

    // MARK: - Borders
    // border-1: primary hairline (cards, sections)
    static let appSeparator = Color(light: .hex(0x000000, opacity: 0.07), dark: .hex(0xFFFFFF, opacity: 0.06))
    // border-2: slightly stronger (ghost-button border)
    static let appBorderStrong = Color(light: .hex(0x000000, opacity: 0.10), dark: .hex(0xFFFFFF, opacity: 0.10))
    // border-3: strongest (checkbox, dashed buttons)
    static let appBorderStrongest = Color(light: .hex(0x000000, opacity: 0.16), dark: .hex(0xFFFFFF, opacity: 0.16))
}

// MARK: - Helpers

extension Color {

    /// Creates an adaptive color that resolves differently in light and dark modes.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
    }

    /// Creates a color from a hex integer, e.g. `Color.hex(0x1C1C1E)`.
    static func hex(_ hex: UInt, opacity: Double = 1.0) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
