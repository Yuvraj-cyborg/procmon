// Layout building blocks shared by every page.
//
// Pages group content with whitespace, not boxes. Panels exist only where a
// surface carries meaning: the home grid, volumes and the storage map.

import SwiftUI

extension EnvironmentValues {
    /// Height of the visible page area, so tall content (tables, the map)
    /// can size itself to the window instead of a fixed number.
    @Entry var viewportHeight: CGFloat = 800
}

/// A quiet surface: no border, no shadow, no icon.
struct Panel<Content: View>: View {
    var padding: CGFloat = Space.l
    /// Fixed height, for grids.
    var height: CGFloat?
    /// Grow to fill the space the parent offers.
    var fills = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: fills ? .infinity : height, alignment: .topLeading)
        .background(Palette.panel, in: .rect(cornerRadius: Layout.panelRadius, style: .continuous))
    }
}

/// A panel's name, with an optional note on the right.
struct PanelTitle: View {
    let title: String
    var detail: String?
    var detailLevel: Level = .normal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(title)
                .font(TextStyle.emphasis)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            if let detail {
                Text(detail)
                    .font(TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(detailLevel == .normal ? Palette.secondaryText : detailLevel.color)
                    .lineLimit(1)
            }
        }
    }
}

/// Makes a whole panel tappable, answering hover and press quietly.
struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration)
    }

    private struct PanelButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: Layout.panelRadius, style: .continuous)
                        .fill(Palette.hover.opacity(configuration.isPressed ? 0.8 : hovering ? 0.35 : 0))
                        .allowsHitTesting(false)
                }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
                .contentShape(.rect(cornerRadius: Layout.panelRadius))
        }
    }
}

/// Page title with facts beside it and actions on the right.
struct PageHeader<Actions: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(title)
                .font(TextStyle.title)
                .foregroundStyle(Palette.text)
            if let detail {
                Text(detail)
                    .font(TextStyle.body)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Space.m)
            HStack(spacing: Space.s) { actions }
                .controlSize(.regular)
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// A titled group of content. Groups are told apart by space alone.
struct PageSection<Trailing: View, Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(title)
                    .font(TextStyle.emphasis)
                    .foregroundStyle(Palette.text)
                if let detail {
                    Text(detail)
                        .font(TextStyle.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.s)
                trailing
            }
            content
        }
    }
}

extension PageSection where Trailing == EmptyView {
    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, detail: detail, trailing: { EmptyView() }, content: content)
    }
}

/// Scrolling page body with consistent margins and a readable maximum width.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var viewportHeight: CGFloat = 800

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                content
            }
            .frame(maxWidth: Layout.maxContentWidth, alignment: .topLeading)
            .padding(.horizontal, Layout.pagePadding)
            .padding(.top, Space.m)
            .padding(.bottom, Layout.pagePadding)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .environment(\.viewportHeight, viewportHeight)
    }
}

/// As tall as the visible page less `reserve`, for lists with their own
/// scrolling. Reads the height inside ``PageScroll``, where it is set.
struct ViewportFrame<Content: View>: View {
    var reserve: CGFloat = 80
    var minimum: CGFloat = 360
    @ViewBuilder var content: Content
    @Environment(\.viewportHeight) private var viewportHeight

    var body: some View {
        content.frame(height: max(minimum, viewportHeight - reserve))
    }
}

/// The number a panel exists for, with its unit in the secondary colour.
struct ValueText: View {
    let value: String
    var unit: String?
    var level: Level = .normal
    var font: Font = TextStyle.hero

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 1 : 3) {
            Text(value)
                .font(font)
                .foregroundStyle(level.color)
            if let unit {
                Text(unit)
                    .font(TextStyle.body)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// A small label over a value, with an optional note beneath.
struct StatView: View {
    let label: String
    let value: String
    var hint: String?
    var level: Level = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TextStyle.caption)
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
            Text(value)
                .font(TextStyle.body)
                .monospacedDigit()
                .foregroundStyle(level.color)
                .lineLimit(1)
            if let hint {
                Text(hint)
                    .font(TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiaryText)
                    .lineLimit(1)
            }
        }
    }
}

/// Plain secondary text for empty and waiting states.
struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(TextStyle.body)
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What an empty area is for, and how to fill it. Centred in its space.
struct Placeholder<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Space.s) {
            Text(title)
                .font(TextStyle.title)
                .foregroundStyle(Palette.text)
            Text(detail)
                .font(TextStyle.body)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) { actions }
                .padding(.top, Space.s)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A button showing a glyph, optionally with a title.
struct GlyphButton: View {
    let glyph: Glyph
    var title: String?
    let help: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ glyph: Glyph, title: String? = nil, help: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.glyph = glyph
        self.title = title
        self.help = help
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                GlyphImage(glyph, size: 13)
                if let title {
                    Text(title)
                }
            }
        }
        .help(help)
        .accessibilityLabel(title ?? help)
    }
}

extension View {
    /// Liquid Glass on macOS 26, a plain material before it. For the
    /// navigation layer and transient overlays only.
    @ViewBuilder
    func glassBackground(in shape: some Shape = .capsule, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Palette.separator, lineWidth: 0.5))
        }
    }
}
