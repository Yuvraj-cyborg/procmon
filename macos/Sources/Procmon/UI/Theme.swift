// Procmon's design tokens.
//
// The rules they encode (see the design notes in the README's history):
// - Grayscale by default; the system accent marks what is interactive or
//   selected; green, amber and red only mean state, and always with words.
// - One family, four sizes (11, 13, 15, 22), two weights; numbers tabular.
// - Space on a 4-point scale; groups sit twice as far apart as their parts.

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
    /// Behind everything.
    static let canvas = Color(light: 0xF4F4F3, dark: 0x1B1B1C)
    /// Panels on the home grid and sheets.
    static let panel = Color(light: 0xFFFFFF, dark: 0x252526)
    /// Row hover and pressed states.
    static let hover = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    static let text = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    /// The empty part of bars and meters.
    static let track = Color(nsColor: .quaternaryLabelColor)
    static let accent = Color.accentColor
}

/// What a value means. Normal things are not coloured.
enum Level: Sendable {
    case normal, warning, critical

    var color: Color {
        switch self {
        case .normal: Palette.text
        case .warning: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        }
    }

    static func load(_ ratio: Ratio) -> Level {
        switch ratio.value {
        case 0.9...: .critical
        case 0.75...: .warning
        default: .normal
        }
    }

    static func pressure(_ pressure: MemoryPressure) -> Level {
        switch pressure {
        case .critical: .critical
        case .warning: .warning
        case .normal, .unknown: .normal
        }
    }
}

enum TextStyle {
    /// Column headers, labels, context under a value.
    static let caption = Font.system(size: 11)
    static let body = Font.system(size: 13)
    static let emphasis = Font.system(size: 13, weight: .semibold)
    /// Page and section titles.
    static let title = Font.system(size: 15, weight: .semibold)
    /// At most one per panel: the number the panel exists for.
    static let hero = Font.system(size: 22, weight: .semibold)
    static let code = Font.system(size: 11, design: .monospaced)
}

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let section: CGFloat = 32
}

enum Layout {
    static let pagePadding: CGFloat = 20
    static let maxContentWidth: CGFloat = 1440
    static let spacing: CGFloat = 12
    static let panelRadius: CGFloat = 10
    /// Home panels share a height so the grid stays tidy.
    static let tileHeight: CGFloat = 184
}

/// File types in the storage map: the one place colour means category,
/// because there the colours are the data.
enum Tint: CaseIterable {
    case blue, green, orange, purple, pink, yellow, red, brown, gray

    var fill: Color {
        switch self {
        case .blue: Color(light: 0xDDE6F0, dark: 0x2A3440)
        case .green: Color(light: 0xDDEBE2, dark: 0x2A3A31)
        case .orange: Color(light: 0xF2E3D6, dark: 0x40322A)
        case .purple: Color(light: 0xE6E0EE, dark: 0x352F40)
        case .pink: Color(light: 0xF0E0E7, dark: 0x3F2E36)
        case .yellow: Color(light: 0xF1EAD2, dark: 0x3D3726)
        case .red: Color(light: 0xF1DEDC, dark: 0x422D2B)
        case .brown: Color(light: 0xEAE3DC, dark: 0x3A322C)
        case .gray: Color(light: 0xEAEAE8, dark: 0x303031)
        }
    }

    var strong: Color {
        switch self {
        case .blue: Color(light: 0x5B87B5, dark: 0x7FA6CF)
        case .green: Color(light: 0x5A9275, dark: 0x7DB597)
        case .orange: Color(light: 0xC07C4E, dark: 0xD99A6E)
        case .purple: Color(light: 0x8570AE, dark: 0xA692CC)
        case .pink: Color(light: 0xB56F8E, dark: 0xD08FAB)
        case .yellow: Color(light: 0xB09448, dark: 0xCDB26A)
        case .red: Color(light: 0xC06A61, dark: 0xDA8B82)
        case .brown: Color(light: 0x93765F, dark: 0xB3957E)
        case .gray: Color(light: 0x8E8D89, dark: 0x8E8D89)
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
}
