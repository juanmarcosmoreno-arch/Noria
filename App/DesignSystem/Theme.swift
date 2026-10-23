import AppKit
import SwiftUI

/// Noria's design tokens. Change brand colors here; every view reads them from this file.
enum NoriaColor {
    static let deepBlue = Color(hex: 0x075B9A)
    static let primaryBlue = Color(hex: 0x087BC1)
    static let brightBlue = Color(hex: 0x00A9E8)
    static let sky = Color(hex: 0x73DDF3)
    static let ink = Color(hex: 0x17232D)

    /// Brand gradient used by the turbine, progress ring and primary buttons.
    static let brandGradient = LinearGradient(
        colors: [sky, brightBlue, primaryBlue, deepBlue],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Card surface: white in light mode, a blue-tinted graphite in dark mode.
    static let cardBackground = Color(light: 0xFFFFFF, dark: 0x1B2630)
    /// Window/content background behind cards.
    static let canvasBackground = Color(light: 0xF4F7FA, dark: 0x111A21)
    static let subtleFill = Color(light: 0xEEF4F9, dark: 0x22303B)
    static let separator = Color(light: 0xE2E9F0, dark: 0x2B3A46)

    static let safe = Color(light: 0x1E9E6A, dark: 0x3CC48C)
    static let review = Color(light: 0xC77A00, dark: 0xF2A93B)
    static let protected = Color(light: 0x6B7785, dark: 0x9AA6B2)
    static let danger = Color(light: 0xD0342C, dark: 0xFF6B61)
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
    static let wordmark = Font.system(size: 22, weight: .medium, design: .rounded)
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
