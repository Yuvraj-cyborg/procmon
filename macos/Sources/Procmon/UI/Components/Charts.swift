// Small charts, drawn as vector shapes.
//
// Following Tufte: lines, not paint. No fills, gradients, frames or legends;
// the newest value is marked where the line ends, and parts are labelled
// directly. Shapes rather than Canvas: every Canvas is rasterised into its own
// GPU layer, which for a screen of charts costs tens of megabytes.

import SwiftUI

/// Recent history as a thin line, newest value on the right, marked by a dot.
struct Sparkline: View {
    let values: [Double]
    let capacity: Int
    /// Fixed top of the scale; `nil` scales to the largest value shown.
    var ceiling: Double?
    var color: Color = Palette.secondaryText

    var body: some View {
        let top = ceiling ?? max(values.max() ?? 1, .leastNonzeroMagnitude)
        let trace = SparklineTrace(values: values, capacity: capacity, ceiling: top)
        ZStack(alignment: .bottom) {
            // A hairline for the time span, so a chart that is still filling
            // up shows how much history it will hold.
            Rectangle().fill(Palette.separator).frame(height: 0.5)
            trace.stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            EndPoint(values: values, capacity: capacity, ceiling: top).fill(color)
        }
        .accessibilityHidden(true)
    }
}

private func sparkPoint(_ index: Int, values: [Double], capacity: Int, ceiling: Double, in rect: CGRect) -> CGPoint {
    let step = rect.width / CGFloat(max(capacity - 1, 1))
    let offset = CGFloat(capacity - values.count) * step
    let ratio = min(max(values[index] / ceiling, 0), 1)
    // Keep a hair of room so the line and its dot are never clipped.
    let inset: CGFloat = 2
    return CGPoint(x: rect.minX + offset + CGFloat(index) * step, y: rect.maxY - inset - CGFloat(ratio) * (rect.height - 2 * inset))
}

private struct SparklineTrace: Shape {
    let values: [Double]
    let capacity: Int
    let ceiling: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        path.move(to: sparkPoint(0, values: values, capacity: capacity, ceiling: ceiling, in: rect))
        for index in 1..<values.count {
            path.addLine(to: sparkPoint(index, values: values, capacity: capacity, ceiling: ceiling, in: rect))
        }
        return path
    }
}

private struct EndPoint: Shape {
    let values: [Double]
    let capacity: Int
    let ceiling: Double

    func path(in rect: CGRect) -> Path {
        guard !values.isEmpty else { return Path() }
        let point = sparkPoint(values.count - 1, values: values, capacity: capacity, ceiling: ceiling, in: rect)
        return Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
    }
}

/// One part of a whole, for ``CompositionBar``.
struct Portion: Identifiable {
    let id: String
    let value: Bytes
}

/// How a whole splits into parts: one thin bar in shades of the text colour,
/// darkest first, labelled directly underneath instead of by a legend.
struct CompositionBar: View {
    let portions: [Portion]
    let total: Bytes

    /// Shades from the text colour, so no part needs a hue of its own.
    private static let shades: [Double] = [0.85, 0.55, 0.35, 0.2, 0.12]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(Array(portions.enumerated()), id: \.element.id) { index, portion in
                        Rectangle()
                            .fill(Palette.text.opacity(Self.shades[min(index, Self.shades.count - 1)]))
                            .frame(width: max(1, proxy.size.width * portion.value.ratio(of: total).value))
                    }
                    Spacer(minLength: 0)
                }
                .background(Palette.track)
            }
            .frame(height: 6)
            .clipShape(.rect(cornerRadius: 3))
            FlowLayout(spacing: Space.m, lineSpacing: Space.xs) {
                ForEach(Array(portions.enumerated()), id: \.element.id) { index, portion in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Palette.text.opacity(Self.shades[min(index, Self.shades.count - 1)]))
                            .frame(width: 8, height: 8)
                        Text(portion.id).foregroundStyle(Palette.secondaryText)
                        Text(portion.value.binary).foregroundStyle(Palette.text)
                    }
                    .lineLimit(1)
                }
            }
            .font(TextStyle.caption)
            .monospacedDigit()
        }
        .accessibilityElement()
        .accessibilityValue(portions.map { "\($0.id) \($0.value.binary)" }.joined(separator: ", "))
    }
}

/// Lays children out in rows, wrapping to a new row when one is full.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = Space.s
    var lineSpacing: CGFloat = Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// How full something is, as a thin bar that turns amber, then red, near the top.
struct Meter: View {
    let ratio: Ratio
    var height: CGFloat = 4
    /// Colour by fullness; off for bars where full is simply the maximum.
    var warns = true

    var body: some View {
        let level = warns ? Level.load(ratio) : .normal
        ZStack(alignment: .leading) {
            Capsule().fill(Palette.track)
            FilledFraction(fraction: ratio.value, axis: .horizontal)
                .fill(level == .normal ? Palette.text.opacity(0.55) : level.color)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(ratio.percent.description)
    }
}

/// One slim bar per logical core: small multiples on a shared scale.
struct CoreBars: View {
    let cores: [Ratio]
    var height: CGFloat = 16

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(cores.indices, id: \.self) { index in
                let load = cores[index]
                let level = Level.load(load)
                ZStack {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Palette.track.opacity(0.6))
                    FilledFraction(fraction: load.value, axis: .vertical)
                        .fill(level == .normal ? Palette.text.opacity(0.5) : level.color)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The filled part of a bar, grown from the leading or bottom edge.
struct FilledFraction: Shape {
    var fraction: Double
    let axis: Axis

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = CGFloat(min(max(fraction, 0), 1))
        let bar: CGRect = switch axis {
        case .horizontal:
            CGRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * clamped), height: rect.height)
        case .vertical:
            CGRect(x: rect.minX, y: rect.maxY - max(1.5, rect.height * clamped), width: rect.width, height: max(1.5, rect.height * clamped))
        }
        let radius = axis == .horizontal ? rect.height / 2 : min(1.5, rect.width / 2)
        return Path(roundedRect: bar, cornerRadius: radius, style: .continuous)
    }
}
