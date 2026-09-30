// The folder map: nested boxes sized by disk usage, drawn in one Canvas.

import SwiftUI

/// One box in the map.
struct TreemapTile {
    /// The node drawn; for an overflow tile, the folder whose children it stands for.
    let id: NodeID
    let rect: CGRect
    /// Top-level tiles are 0; each level of boxes inside a folder adds one.
    let depth: Int
    /// A folder large enough to show its contents inside it.
    let isNestedContainer: Bool
    /// The children too small to draw individually, as one box.
    var isOverflow = false
    let category: FileCategory
    let name: String
    let size: String
}

enum TreemapLayout {
    /// Tiles beyond this many are too small to see; they would only cost layout time.
    static let maxTiles = 150
    static let maxSubtiles = 60
    /// Levels of folders that show their contents inside them.
    static let maxDepth = 3
    /// Upper bound on tiles per map, however deep the tree.
    static let tileBudget = 2_500
    /// Space between neighbouring tiles.
    static let gap: CGFloat = 3
    /// Height of the name strip on folders that show their contents.
    static let header: CGFloat = 20
    /// Folders at least this large reveal a second level of tiles.
    static let nestMinimum = CGSize(width: 120, height: 80)
    /// Tiles at least this large get a name and size label.
    static let labelMinimum = CGSize(width: 56, height: 30)

    static func tiles(_ tree: FileTree, current: NodeID, in size: CGSize) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        var budget = tileBudget
        layout(tree, parent: current, in: CGRect(origin: .zero, size: size), depth: 0, into: &tiles, budget: &budget)
        return tiles
    }

    /// Lays out `parent`'s children in `bounds`; folders with room for it show
    /// their own children inside, below a name strip.
    private static func layout(
        _ tree: FileTree,
        parent: NodeID,
        in bounds: CGRect,
        depth: Int,
        into tiles: inout [TreemapTile],
        budget: inout Int
    ) {
        let all = tree[parent].children
        let children = Array(all.prefix(depth == 0 ? maxTiles : maxSubtiles))
        // Children beyond the limit still take their share of the space, as
        // one box, so the drawn ones keep their true proportions.
        let omitted = all.dropFirst(children.count)
        let rest = omitted.reduce(Bytes.zero) { $0 + tree[$1].size }
        let rects = Treemap.squarify(children.map { Double(tree[$0].size.value) } + [Double(rest.value)], in: bounds)
        if !omitted.isEmpty, let last = rects.last, last.width >= 1, last.height >= 1 {
            tiles.append(TreemapTile(
                id: parent, rect: last.shrunk(by: gap / 2), depth: depth, isNestedContainer: false,
                isOverflow: true, category: .remainder, name: "\(omitted.count) more", size: rest.decimal
            ))
        }
        for (id, rect) in zip(children, rects) where rect.width >= 1 && rect.height >= 1 {
            guard budget > 0 else { return }
            budget -= 1
            let node = tree[id]
            let box = rect.shrunk(by: gap / 2)
            let nested = depth < maxDepth && node.isContainer
                && box.width >= nestMinimum.width && box.height >= nestMinimum.height
            tiles.append(TreemapTile(
                id: id, rect: box, depth: depth, isNestedContainer: nested,
                category: node.category, name: node.name, size: node.size.decimal
            ))
            if nested {
                let inner = CGRect(x: box.minX + 3, y: box.minY + header, width: box.width - 6, height: box.height - header - 3)
                layout(tree, parent: id, in: inner, depth: depth + 1, into: &tiles, budget: &budget)
            }
        }
    }

    /// The deepest tile under `point`.
    static func hit(_ tiles: [TreemapTile], at point: CGPoint) -> TreemapTile? {
        // Nested tiles come after their container, so search backwards.
        tiles.last { $0.rect.contains(point) }
    }
}

/// Remembers the last layout so hovering never recomputes it.
@MainActor
private final class LayoutCache {
    struct Key: Equatable {
        let root: String
        let current: NodeID
        let revision: Int
        let size: CGSize
    }

    private var key: Key?
    private(set) var tiles: [TreemapTile] = []

    func tiles(for key: Key, tree: FileTree) -> [TreemapTile] {
        if key != self.key {
            tiles = TreemapLayout.tiles(tree, current: key.current, in: key.size)
            self.key = key
        }
        return tiles
    }
}

struct TreemapView: View {
    let tree: FileTree
    let current: NodeID
    let revision: Int
    let selected: NodeID?
    @Binding var hovered: NodeID?
    @Environment(AppModel.self) private var model
    @State private var cache = LayoutCache()
    @State private var size = CGSize(width: 800, height: 420)
    @State private var hoverPoint: CGPoint?

    var body: some View {
        let key = LayoutCache.Key(root: tree.rootPath, current: current, revision: revision, size: size)
        let tiles = cache.tiles(for: key, tree: tree)
        let hoveredTile = hoverPoint.flatMap { TreemapLayout.hit(tiles, at: $0) }
        ZStack(alignment: .topLeading) {
            TreemapCanvas(tiles: tiles, selected: selected, layoutKey: key)
                .equatable()
            if let hoveredTile {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.accent.opacity(0.7), lineWidth: 1.5))
                    .frame(width: hoveredTile.rect.width, height: hoveredTile.rect.height)
                    .offset(x: hoveredTile.rect.minX, y: hoveredTile.rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .contentShape(.rect)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoverPoint = point
                hovered = TreemapLayout.hit(tiles, at: point)?.id
            case .ended:
                hoverPoint = nil
                hovered = nil
            }
        }
        .onTapGesture { point in
            guard let tile = TreemapLayout.hit(tiles, at: point) else { return }
            if tree[tile.id].isContainer {
                withAnimation(.snappy(duration: 0.25)) { model.storage.focus(tile.id) }
            } else {
                model.storage.select(tile.id == selected ? nil : tile.id)
            }
        }
        .contextMenu { contextMenu }
        .overlay {
            if tiles.isEmpty {
                EmptyState(symbol: "folder", title: "Empty folder", detail: "Nothing here takes up space.")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of \(tree.title(of: current)), \(tree[current].children.count) items")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let id = hovered, tree.contains(id) {
            let node = tree[id]
            if node.isContainer {
                Button("Open") { model.storage.focus(id) }
            }
            if let path = tree.path(of: id) {
                Button("Reveal in Finder") { Finder.reveal(path) }
                Divider()
                Button("Move to Trash…", role: .destructive) { model.confirmTrash(id) }
            }
        }
    }
}

/// Draws every tile. Equatable on its layout, so hover changes never redraw it.
private struct TreemapCanvas: View, Equatable {
    let tiles: [TreemapTile]
    let selected: NodeID?
    let layoutKey: LayoutCache.Key

    nonisolated static func == (lhs: TreemapCanvas, rhs: TreemapCanvas) -> Bool {
        lhs.layoutKey == rhs.layoutKey && lhs.selected == rhs.selected
    }

    var body: some View {
        Canvas { context, _ in
            for tile in tiles {
                let shape = Path(roundedRect: tile.rect, cornerRadius: tile.depth == 0 ? 6 : 4, style: .continuous)
                if tile.isOverflow {
                    context.fill(shape, with: .color(Palette.track.opacity(0.7)))
                    if tile.rect.width >= TreemapLayout.labelMinimum.width && tile.rect.height >= 18 {
                        draw(label: tile.name, detail: nil, in: tile.rect.insetBy(dx: 6, dy: 4), bold: false, context: &context)
                    }
                    continue
                }
                if tile.isNestedContainer {
                    // Alternate shades so each level of nesting reads as its own layer.
                    context.fill(shape, with: .color(tile.depth.isMultiple(of: 2) ? Palette.well : Palette.surface))
                    context.stroke(shape, with: .color(Palette.border), lineWidth: 1)
                    let strip = CGRect(x: tile.rect.minX + 7, y: tile.rect.minY + 3, width: tile.rect.width - 14, height: TreemapLayout.header - 4)
                    draw(label: tile.name, detail: tile.size, in: strip, bold: true, context: &context)
                    continue
                }
                context.fill(shape, with: .color(Tint.category(tile.category).fill))
                if tile.id == selected {
                    context.stroke(shape, with: .color(Palette.accent), lineWidth: 2)
                }
                if tile.rect.width >= TreemapLayout.labelMinimum.width && tile.rect.height >= TreemapLayout.labelMinimum.height {
                    let inner = tile.rect.insetBy(dx: 6, dy: 5)
                    draw(label: tile.name, detail: nil, in: inner, bold: false, context: &context)
                    if inner.height >= 30 {
                        draw(detail: tile.size, at: CGPoint(x: inner.minX, y: inner.minY + 15), width: inner.width, context: &context)
                    }
                }
            }
        }
    }

    /// Characters that fit in `width` at the label size, roughly.
    private func fitted(_ text: String, width: CGFloat, perCharacter: CGFloat = 6.4) -> String? {
        let limit = Int(width / perCharacter)
        guard limit >= 3 else { return nil }
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private func draw(label: String, detail: String?, in rect: CGRect, bold: Bool, context: inout GraphicsContext) {
        let detailWidth: CGFloat = detail.map { CGFloat($0.count) * 6.2 + 12 } ?? 0
        if let name = fitted(label, width: rect.width - detailWidth, perCharacter: bold ? 7.2 : 6.6) {
            context.draw(
                Text(name).font(.system(size: 11, weight: bold ? .semibold : .medium)).foregroundStyle(Palette.text),
                at: CGPoint(x: rect.minX, y: rect.minY), anchor: .topLeading
            )
        }
        if let detail, rect.width > detailWidth + 40 {
            context.draw(
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText),
                at: CGPoint(x: rect.maxX, y: rect.minY + 0.5), anchor: .topTrailing
            )
        }
    }

    private func draw(detail: String, at point: CGPoint, width: CGFloat, context: inout GraphicsContext) {
        guard let text = fitted(detail, width: width, perCharacter: 6) else { return }
        context.draw(Text(text).font(.system(size: 10.5)).foregroundStyle(Palette.secondaryText), at: point, anchor: .topLeading)
    }
}
