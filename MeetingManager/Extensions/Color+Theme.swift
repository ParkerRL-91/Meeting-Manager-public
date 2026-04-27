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

    // Backgrounds
    static let appBackground = Color(light: .hex(0xFFFFFF), dark: .hex(0x1C1C1E))
    static let appSurface = Color(light: .hex(0xF2F2F7), dark: .hex(0x2C2C2E))
    static let appSurfaceSecondary = Color(light: .hex(0xE5E5EA), dark: .hex(0x3A3A3C))

    // Text
    static let appTextPrimary = Color(light: .hex(0x000000), dark: .hex(0xFFFFFF))
    static let appTextSecondary = Color(light: .hex(0x8E8E93), dark: .hex(0xAEAEB2))
    static let appTextTertiary = Color(light: .hex(0xC7C7CC), dark: .hex(0x636366))

    // Accents
    static let appAccent = Color(light: .hex(0x007AFF), dark: .hex(0x0A84FF))
    static let appRecording = Color(light: .hex(0xFF3B30), dark: .hex(0xFF453A))
    static let appSuccess = Color(light: .hex(0x34C759), dark: .hex(0x30D158))
    static let appWarning = Color(light: .hex(0xFF9500), dark: .hex(0xFF9F0A))

    // Dividers
    static let appSeparator = Color(light: .hex(0xD1D1D6), dark: .hex(0x48484A))
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
