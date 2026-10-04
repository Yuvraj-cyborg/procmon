// Generated from the Procmon glyph set: 20 glyphs on a 16-point
// keyline grid, 1.5 pt strokes with round caps and joins. Drawn as paths,
// so they cost no image assets and stay sharp at any size.

import SwiftUI

enum Glyph: CaseIterable, Sendable {
    case overview, memory, activity, storage, devices, search, close, settings, inspector, refresh, arrowUp, folder, trash, quit, forceQuit, pause, play, chevron, lock, threads

    /// Stroke width at the design size; scales with the glyph.
    static let stroke: CGFloat = 1.5
    static let grid: CGFloat = 16.0

    /// The glyph's outline (`filled == false`) or its solid details.
    func path(in rect: CGRect, filled: Bool) -> Path {
        let u = min(rect.width, rect.height) / Self.grid
        let origin = CGPoint(x: rect.midX - Self.grid * u / 2, y: rect.midY - Self.grid * u / 2)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * u, y: origin.y + y * u) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: origin.x + x * u, y: origin.y + y * u, width: w * u, height: h * u)
        }
        func size(_ r: CGFloat) -> CGSize { CGSize(width: r * u, height: r * u) }
        func onCircle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ degrees: CGFloat) -> CGPoint {
            let a = (degrees - 90) * .pi / 180
            return pt(cx + r * cos(a), cy + r * sin(a))
        }
        var p = Path()
        switch self {
        case .overview:
            if filled {
                return p
            } else {
            p.addRoundedRect(in: box(1.75, 1.75, 4.75, 4.75), cornerSize: size(1), style: .continuous)
            p.addRoundedRect(in: box(9.5, 1.75, 4.75, 4.75), cornerSize: size(1), style: .continuous)
            p.addRoundedRect(in: box(1.75, 9.5, 4.75, 4.75), cornerSize: size(1), style: .continuous)
            p.addRoundedRect(in: box(9.5, 9.5, 4.75, 4.75), cornerSize: size(1), style: .continuous)
            }
        case .memory:
            if filled {
                return p
            } else {
            p.addRoundedRect(in: box(1.75, 3.25, 12.5, 7.75), cornerSize: size(1.5), style: .continuous)
            p.move(to: pt(4.5, 11)); p.addLine(to: pt(4.5, 13.5))
            p.move(to: pt(8, 11)); p.addLine(to: pt(8, 13.5))
            p.move(to: pt(11.5, 11)); p.addLine(to: pt(11.5, 13.5))
            p.addRoundedRect(in: box(5, 6, 6, 2.25), cornerSize: size(0.5), style: .continuous)
            }
        case .activity:
            if filled {
                return p
            } else {
            p.addLines([pt(1.5, 8.5), pt(4.5, 8.5), pt(6.25, 3.5), pt(9.5, 12.5), pt(11.25, 8.5), pt(14.5, 8.5)])
            }
        case .storage:
            if filled {
            p.addEllipse(in: box(10.65, 4.15, 1.7, 1.7))
            p.addEllipse(in: box(10.65, 10.15, 1.7, 1.7))
            } else {
            p.addRoundedRect(in: box(1.75, 2.75, 12.5, 4.5), cornerSize: size(1.5), style: .continuous)
            p.addRoundedRect(in: box(1.75, 8.75, 12.5, 4.5), cornerSize: size(1.5), style: .continuous)
            }
        case .devices:
            if filled {
                return p
            } else {
            p.addRoundedRect(in: box(4.25, 4.75, 7.5, 5.5), cornerSize: size(1.5), style: .continuous)
            p.move(to: pt(6.25, 1.75)); p.addLine(to: pt(6.25, 4.75))
            p.move(to: pt(9.75, 1.75)); p.addLine(to: pt(9.75, 4.75))
            p.move(to: pt(8, 10.25)); p.addLine(to: pt(8, 14.25))
            }
        case .search:
            if filled {
                return p
            } else {
            p.addEllipse(in: box(2.25, 2.25, 9.5, 9.5))
            p.move(to: pt(10.5, 10.5)); p.addLine(to: pt(14, 14))
            }
        case .close:
            if filled {
                return p
            } else {
            p.move(to: pt(4, 4)); p.addLine(to: pt(12, 12))
            p.move(to: pt(12, 4)); p.addLine(to: pt(4, 12))
            }
        case .settings:
            if filled {
                return p
            } else {
            p.move(to: pt(1.75, 5)); p.addLine(to: pt(8, 5))
            p.move(to: pt(13, 5)); p.addLine(to: pt(14.25, 5))
            p.addEllipse(in: box(8.75, 3.25, 3.5, 3.5))
            p.move(to: pt(1.75, 11)); p.addLine(to: pt(3, 11))
            p.move(to: pt(8, 11)); p.addLine(to: pt(14.25, 11))
            p.addEllipse(in: box(3.75, 9.25, 3.5, 3.5))
            }
        case .inspector:
            if filled {
                return p
            } else {
            p.addRoundedRect(in: box(1.75, 2.75, 12.5, 10.5), cornerSize: size(2), style: .continuous)
            p.move(to: pt(9.75, 2.75)); p.addLine(to: pt(9.75, 13.25))
            }
        case .refresh:
            if filled {
                return p
            } else {
            p.move(to: onCircle(8, 8.5, 5.25, 60)); p.addArc(center: pt(8, 8.5), radius: 5.25 * u, startAngle: .degrees(-30), endAngle: .degrees(270), clockwise: false)
            p.addLines([pt(6.5, 1.5), pt(8.5, 3.25), pt(6.5, 5)])
            }
        case .arrowUp:
            if filled {
                return p
            } else {
            p.move(to: pt(8, 13.5)); p.addLine(to: pt(8, 2.75))
            p.addLines([pt(3.75, 7), pt(8, 2.75), pt(12.25, 7)])
            }
        case .folder:
            if filled {
                return p
            } else {
            p.addLines([pt(1.75, 12.25), pt(1.75, 3.25), pt(6, 3.25), pt(7.5, 5.25), pt(14.25, 5.25), pt(14.25, 12.25), pt(1.75, 12.25)]); p.closeSubpath()
            }
        case .trash:
            if filled {
                return p
            } else {
            p.move(to: pt(1.75, 4)); p.addLine(to: pt(14.25, 4))
            p.addLines([pt(6, 4), pt(6, 1.75), pt(10, 1.75), pt(10, 4)])
            p.addLines([pt(3.25, 4), pt(4.25, 14.25), pt(11.75, 14.25), pt(12.75, 4)])
            }
        case .quit:
            if filled {
                return p
            } else {
            p.move(to: onCircle(8, 8.5, 5.75, 40)); p.addArc(center: pt(8, 8.5), radius: 5.75 * u, startAngle: .degrees(-50), endAngle: .degrees(230), clockwise: false)
            p.move(to: pt(8, 1.5)); p.addLine(to: pt(8, 7.25))
            }
        case .forceQuit:
            if filled {
                return p
            } else {
            p.addLines([pt(5.25, 1.75), pt(10.75, 1.75), pt(14.25, 5.25), pt(14.25, 10.75), pt(10.75, 14.25), pt(5.25, 14.25), pt(1.75, 10.75), pt(1.75, 5.25)]); p.closeSubpath()
            p.move(to: pt(5, 8)); p.addLine(to: pt(11, 8))
            }
        case .pause:
            if filled {
                return p
            } else {
            p.move(to: pt(5.5, 3.5)); p.addLine(to: pt(5.5, 12.5))
            p.move(to: pt(10.5, 3.5)); p.addLine(to: pt(10.5, 12.5))
            }
        case .play:
            if filled {
                return p
            } else {
            p.addLines([pt(4.75, 2.75), pt(13, 8), pt(4.75, 13.25)]); p.closeSubpath()
            }
        case .chevron:
            if filled {
                return p
            } else {
            p.addLines([pt(6, 3.5), pt(10.5, 8), pt(6, 12.5)])
            }
        case .lock:
            if filled {
            p.addEllipse(in: box(7.15, 9.9, 1.7, 1.7))
            } else {
            p.addRoundedRect(in: box(3.25, 7.25, 9.5, 7), cornerSize: size(1.5), style: .continuous)
            p.move(to: onCircle(8, 7.25, 3, 270)); p.addArc(center: pt(8, 7.25), radius: 3 * u, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            }
        case .threads:
            if filled {
            p.addEllipse(in: box(11.15, 6.9, 2.2, 2.2))
            } else {
            p.move(to: pt(1.75, 4)); p.addLine(to: pt(14.25, 4))
            p.move(to: pt(1.75, 8)); p.addLine(to: pt(9, 8))
            p.move(to: pt(1.75, 12)); p.addLine(to: pt(14.25, 12))
            }
        }
        return p
    }
}

/// A glyph drawn at `size` points in the current foreground style.
struct GlyphImage: View {
    let glyph: Glyph
    var size: CGFloat = 16

    init(_ glyph: Glyph, size: CGFloat = 16) {
        self.glyph = glyph
        self.size = size
    }

    var body: some View {
        ZStack {
            GlyphShape(glyph: glyph, filled: false)
                .stroke(style: StrokeStyle(lineWidth: Glyph.stroke * size / Glyph.grid, lineCap: .round, lineJoin: .round))
            GlyphShape(glyph: glyph, filled: true)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct GlyphShape: Shape {
    let glyph: Glyph
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        glyph.path(in: rect, filled: filled)
    }
}
