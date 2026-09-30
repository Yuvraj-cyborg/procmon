// Small, dependency-free charts built from vector shapes.
//
// These deliberately avoid `Canvas`: every Canvas is rasterised into its own
// GPU-backed layer, which for a screen of sparklines and meters costs tens of
// megabytes. Shapes are drawn straight from SwiftUI's display list.

import SwiftUI

/// One coloured part of a ``Meter``.
struct MeterSegment: Identifiable {
    let id: String
    let ratio: Ratio
    let color: Color
}

/// A horizontal bar split into coloured segments over a neutral track.
struct Meter: View {
    let segments: [MeterSegment]
    var height: CGFloat = 8

    init(segments: [MeterSegment], height: CGFloat = 8) {
        self.segments = segments
        self.height = height
    }

    init(_ ratio: Ratio, color: Color, height: CGFloat = 6) {
        self.init(segments: [MeterSegment(id: "value", ratio: ratio, color: color)], height: height)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                // A hairline gap keeps adjacent segments distinguishable.
                HStack(spacing: 1.5) {
                    ForEach(segments.filter { $0.ratio.value > 0 }) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(1.5, proxy.size.width * segment.ratio.value))
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(.capsule)
        .accessibilityElement()
        .accessibilityValue(segments.map { "\($0.id) \($0.ratio.percent.description)" }.joined(separator: ", "))
    }
}

/// Recent history as a line with a soft fill, newest value on the right.
struct Sparkline: View {
    let values: [Double]
    let capacity: Int
    var color: Color = Palette.accent
    /// Fixed top of the scale; `nil` scales to the largest value shown.
    var ceiling: Double?

    var body: some View {
        let trace = SparklineTrace(values: values, capacity: capacity, ceiling: ceiling ?? max(values.max() ?? 1, .leastNonzeroMagnitude))
        ZStack {
            trace.area.fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            trace.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// The line (or, with `closed`, the filled area) of a sparkline.
private struct SparklineTrace: Shape {
    let values: [Double]
    let capacity: Int
    let ceiling: Double
    var closed = false

    var area: SparklineTrace { SparklineTrace(values: values, capacity: capacity, ceiling: ceiling, closed: true) }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(max(capacity - 1, 1))
        let offset = CGFloat(capacity - values.count) * step
        func point(_ index: Int) -> CGPoint {
            let ratio = min(max(values[index] / ceiling, 0), 1)
            return CGPoint(x: rect.minX + offset + CGFloat(index) * step, y: rect.maxY - 1 - CGFloat(ratio) * (rect.height - 2))
        }
        path.move(to: point(0))
        for index in 1..<values.count {
            path.addLine(to: point(index))
        }
        if closed {
            path.addLine(to: CGPoint(x: point(values.count - 1).x, y: rect.maxY))
            path.addLine(to: CGPoint(x: point(0).x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// One slim vertical bar per logical core.
struct CoreBars: View {
    let cores: [Ratio]
    var height: CGFloat = 18

    var body: some View {
        HStack(spacing: 3) {
            ForEach(cores.indices, id: \.self) { index in
                let load = cores[index]
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.track)
                    FilledFraction(fraction: load.value, axis: .vertical)
                        .fill(Tint.load(load).strong)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A thin inline bar for list rows.
struct UsageBar: View {
    let ratio: Ratio
    var color: Color = Palette.accent

    var body: some View {
        ZStack {
            Capsule().fill(Palette.track)
            FilledFraction(fraction: ratio.value, axis: .horizontal).fill(color)
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The filled part of a bar, grown from the leading or bottom edge. Its
/// fraction animates when the value changes.
private struct FilledFraction: Shape {
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
            CGRect(x: rect.minX, y: rect.maxY - max(2, rect.height * clamped), width: rect.width, height: max(2, rect.height * clamped))
        }
        let radius = min(3, rect.width / 2, rect.height / 2)
        return Path(roundedRect: bar, cornerRadius: axis == .horizontal ? rect.height / 2 : radius, style: .continuous)
    }
}
