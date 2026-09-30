// Layout building blocks shared by every page.

import SwiftUI

extension EnvironmentValues {
    /// Height of the visible page area, so tall content (tables, the treemap)
    /// can size itself to the window instead of a fixed number.
    @Entry var viewportHeight: CGFloat = 800
}

/// A rounded, bordered surface that groups related content.
struct Card<Content: View>: View {
    var padding: CGFloat = Layout.cardPadding
    /// Fixed height, for grids and cards that hold scrolling content.
    var height: CGFloat?
    /// Grow to fill the space the parent offers.
    var fills = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: fills ? .infinity : height, alignment: .topLeading)
        .background(Palette.surface, in: .rect(cornerRadius: Layout.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 1)
        }
    }
}

/// Title row of a card: a tinted glyph, a name and optional trailing detail.
struct CardHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    var tint: Tint = .gray
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.strong)
                .frame(width: 22, height: 22)
                .background(tint.fill, in: .rect(cornerRadius: 6, style: .continuous))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, symbol: String, tint: Tint = .gray) {
        self.init(title: title, symbol: symbol, tint: tint) { EmptyView() }
    }
}

/// Makes a whole card tappable, with a quiet hover and press response.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration)
    }

    private struct CardButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                        .strokeBorder(Palette.accent.opacity(hovering ? 0.45 : 0), lineWidth: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.992 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(.rect(cornerRadius: Layout.cardRadius))
        }
    }
}

/// A card as tall as the visible page, less `reserve`, for lists with their
/// own scrolling. It reads the height inside ``PageScroll``, where it is set.
struct ViewportCard<Content: View>: View {
    var reserve: CGFloat = 96
    var minimum: CGFloat = 420
    @ViewBuilder var content: Content
    @Environment(\.viewportHeight) private var viewportHeight

    var body: some View {
        Card(height: max(minimum, viewportHeight - reserve)) { content }
    }
}

/// Page title with a one-line description and optional actions.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions }
                .controlSize(.regular)
        }
        .padding(.bottom, 2)
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Scrolling page body with consistent margins and a readable maximum width.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var viewportHeight: CGFloat = 800

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                content
            }
            .frame(maxWidth: Layout.maxContentWidth, alignment: .topLeading)
            .padding(.horizontal, Layout.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, Layout.pagePadding)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .environment(\.viewportHeight, viewportHeight)
    }
}

/// A small rounded label, e.g. a status or a reason.
struct Tag: View {
    let text: String
    var tint: Tint = .gray
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint.strong)
        .background(tint.fill, in: .capsule)
    }
}

/// A labelled value, optionally with a colour key and a hint underneath.
struct StatView: View {
    let label: String
    let value: String
    var hint: String?
    var dot: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiaryText)
                    .lineLimit(1)
            }
        }
    }
}

/// The headline number of a card, e.g. "42 %".
struct Figure: View {
    let value: String
    var unit: String?
    var size: CGFloat = 30

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: size, weight: .semibold))
                .tracking(-0.4)
            if let unit {
                Text(unit)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .monospacedDigit()
        .foregroundStyle(Palette.text)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .contentTransition(.numericText())
    }
}

/// Centered glyph with a title and an explanation, for empty or waiting states.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.tertiaryText)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.text)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            actions.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

extension View {
    /// Liquid Glass on macOS 26, a plain material before it.
    @ViewBuilder
    func glassBackground(in shape: some Shape = .capsule, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Palette.border, lineWidth: 0.5))
        }
    }
}
