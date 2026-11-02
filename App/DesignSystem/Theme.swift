import AppKit
import SwiftUI

/// Noria's design tokens. Change brand colors here; every view reads them from this file.
enum NoriaColor {
    // Brand palette (carpentry): wood, light orange, beige, graphite and steel.
    static let wood = Color(hex: 0xD67B2D)
    static let woodLight = Color(hex: 0xF5A462)
    static let woodDark = Color(hex: 0xA9561B)
    static let beige = Color(hex: 0xF7F4EE)
    static let graphite = Color(hex: 0x1F2328)
    static let steelDark = Color(hex: 0x3A3D42)
    static let steelMid = Color(hex: 0x6B6F76)
    static let steel = Color(hex: 0xC0C4C9)
    static let steelLight = Color(hex: 0xE6E7E9)

    /// Accent used for selection, icons, primary actions and progress.
    static let accent = wood

    /// Warm gradient for primary buttons, progress and capacity bars.
    static let woodGradient = LinearGradient(colors: [woodLight, wood], startPoint: .top, endPoint: .bottom)

    /// Card surface: white in light mode, warm graphite in dark mode.
    static let cardBackground = Color(light: 0xFFFFFF, dark: 0x24262A)
    /// Window/content background behind cards.
    static let canvasBackground = Color(light: 0xF7F4EE, dark: 0x1A1A1A)
    static let subtleFill = Color(light: 0xF1ECE4, dark: 0x2D3034)
    static let separator = Color(light: 0xE7E0D5, dark: 0x36393E)

    static let safe = Color(light: 0x2F8F5B, dark: 0x4CC28A)
    static let review = Color(light: 0xB7791F, dark: 0xE7B04B)
    static let protected = Color(light: 0x6B6F76, dark: 0x9EA3AA)
    static let danger = Color(light: 0xC2382F, dark: 0xFF6B61)
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
