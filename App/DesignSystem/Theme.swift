import AppKit
import SwiftUI

/// Noria's design tokens. Change brand colors here; every view reads them from this file.
enum NoriaColor {
    // Brand palette (water wheel): deep, ocean, sky and foam blues, mist and ink.
    static let deep = Color(hex: 0x0A5FA8)
    static let ocean = Color(hex: 0x1689DB)
    static let sky = Color(hex: 0x2EB4EE)
    static let foam = Color(hex: 0x8FDCF7)
    static let mist = Color(hex: 0xE8F6FD)
    static let ink = Color(hex: 0x1A1F26)
    static let slate = Color(light: 0x6B7380, dark: 0x9AA2AD)

    /// Accent used for selection, icons, primary actions and progress.
    static let accent = Color(light: 0x1689DB, dark: 0x3AA8F0)

    /// Primary buttons, progress rings and capacity bars.
    static let accentGradient = LinearGradient(colors: [Color(hex: 0x2EB4EE), Color(hex: 0x1679D2)],
                                               startPoint: .top, endPoint: .bottom)

    /// Card surface: white in light mode, graphite in dark mode.
    static let cardBackground = Color(light: 0xFFFFFF, dark: 0x25282D)
    /// Window/content background behind cards.
    static let canvasBackground = Color(light: 0xF4F6F9, dark: 0x1B1D21)
    static let subtleFill = Color(light: 0xEEF2F6, dark: 0x30343A)
    static let separator = Color(light: 0xE2E7ED, dark: 0x3A3F46)

    static let safe = Color(light: 0x23965A, dark: 0x4CC28A)
    static let review = Color(light: 0xC27A12, dark: 0xF0B44C)
    static let protected = Color(light: 0x6B7380, dark: 0x9AA2AD)
    static let danger = Color(light: 0xD23B32, dark: 0xFF6B61)
}

enum NoriaSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

enum NoriaRadius {
    static let small: CGFloat = 8
    static let card: CGFloat = 16
    static let large: CGFloat = 22
}

/// SF Pro through system fonts, so Dynamic Type-like scaling and localization keep working.
enum NoriaFont {
    static let heroValue = Font.system(size: 40, weight: .semibold, design: .rounded)
    static let title = Font.system(size: 26, weight: .semibold)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let metric = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    static let wordmark = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let tagline = Font.system(size: 9, weight: .medium)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// A color that adapts to light and dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
