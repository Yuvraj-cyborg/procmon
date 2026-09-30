// Procmon's palette: warm paper neutrals with a soft indigo accent, in light
// and dark variants that follow the window's appearance.

import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// A colour that switches with the appearance it is drawn in.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

enum Palette {
    /// Window background behind the cards.
    static let canvas = Color(light: 0xF6F5F2, dark: 0x141413)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1E1E1D)
    static let surfaceHover = Color(light: 0xFAFAF8, dark: 0x252524)
    /// Recessed wells inside a card, e.g. behind charts.
    static let well = Color(light: 0xF6F5F2, dark: 0x191918)
    static let border = Color(light: 0xE8E7E3, dark: 0x2B2B2A)
    static let track = Color(light: 0xECEBE7, dark: 0x2F2F2E)
    static let text = Color(light: 0x2F2E2A, dark: 0xE8E7E4)
    static let secondaryText = Color(light: 0x7A7873, dark: 0x9C9B96)
    static let tertiaryText = Color(light: 0xA9A7A1, dark: 0x6C6B67)
    static let accent = Color(light: 0x5E6AD2, dark: 0x8C95EE)
}

/// A soft categorical colour, used for treemap tiles, legends and tags.
enum Tint: CaseIterable {
    case blue, green, orange, purple, pink, yellow, red, brown, gray

    /// Pastel fill, readable with the theme text on top.
    var fill: Color {
        switch self {
        case .blue: Color(light: 0xDCE8F5, dark: 0x243447)
        case .green: Color(light: 0xDCEEDF, dark: 0x243B31)
        case .orange: Color(light: 0xFAE3CF, dark: 0x46301F)
        case .purple: Color(light: 0xE9E0F3, dark: 0x362B47)
        case .pink: Color(light: 0xF6E0EA, dark: 0x44283A)
        case .yellow: Color(light: 0xFBEFCB, dark: 0x453A1C)
        case .red: Color(light: 0xFBE0DD, dark: 0x4A2725)
        case .brown: Color(light: 0xEEE3DA, dark: 0x3B2F27)
        case .gray: Color(light: 0xEDECE9, dark: 0x2C2C2B)
        }
    }

    /// Saturated variant for strokes, dots and bar fills.
    var strong: Color {
        switch self {
        case .blue: Color(light: 0x4A8FC2, dark: 0x5FA6D6)
        case .green: Color(light: 0x3E9E8C, dark: 0x55B8A5)
        case .orange: Color(light: 0xDB7E40, dark: 0xE8955C)
        case .purple: Color(light: 0x8C5FCC, dark: 0xA682E0)
        case .pink: Color(light: 0xCC5E93, dark: 0xDD78A9)
        case .yellow: Color(light: 0xC9952E, dark: 0xDDAE4E)
        case .red: Color(light: 0xD65850, dark: 0xE8706A)
        case .brown: Color(light: 0x98705D, dark: 0xB08674)
        case .gray: Color(light: 0x93918C, dark: 0x8F8E8A)
        }
    }
}

extension Tint {
    /// Colour for a load level: calm until it is high.
    static func load(_ ratio: Ratio) -> Tint {
        switch ratio.value {
        case 0.85...: .red
        case 0.6...: .orange
        default: .blue
        }
    }

    static func category(_ category: FileCategory) -> Tint {
        switch category {
        case .folder: .blue
        case .application: .purple
        case .image: .pink
        case .video: .red
        case .audio: .yellow
        case .archive: .orange
        case .document: .green
        case .code: .brown
        case .remainder, .other: .gray
        }
    }

    static func pressure(_ pressure: MemoryPressure) -> Tint {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .gray
        }
    }
}

enum Layout {
    static let pagePadding: CGFloat = 24
    static let maxContentWidth: CGFloat = 1440
    static let spacing: CGFloat = 14
    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    /// Overview cards share a height so the grid stays tidy.
    static let tileHeight: CGFloat = 196
}
