// Volumes, and a scan drawn as boxes you can click into.

import AppKit
import SwiftUI

struct StoragePage: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: NodeID?

    private var storage: StorageModel { model.storage }

    // The map takes whatever height the window has left; the page only
    // scrolls once the window is too short for a useful map.
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content.frame(height: max(proxy.size.height, 560))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // A hovered id belongs to one tree: a new scan or an edited tree
        // starts without one, since no hover-ended event arrives for it.
        .onChange(of: [storage.generation, storage.browser?.revision ?? -1]) { hovered = nil }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            PageHeader(title: Page.storage.title, subtitle: Page.storage.subtitle) {
                Button {
                    storage.scan(NSHomeDirectory())
                } label: {
                    Label("Scan Home", systemImage: "house")
                }
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
            }
            volumes
            Card(fills: true) {
                scanArea
            }
            .frame(minHeight: 300)
        }
        .frame(maxWidth: Layout.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Layout.pagePadding)
        .padding(.top, 12)
        .padding(.bottom, Layout.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to measure."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { storage.scan(url.path) }
        }
    }

    // MARK: Volumes

    private var volumes: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Layout.spacing) {
                ForEach(storage.volumes) { volume in
                    volumeCard(volume)
                }
            }
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
    }

    private func volumeCard(_ volume: Volume) -> some View {
        let used = volume.used.ratio(of: volume.total)
        return Card {
                    HStack(spacing: 10) {
                        Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(Palette.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.text)
                                .lineLimit(1)
                            Text([volume.mountPoint, volume.format].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        Button("Scan") { storage.scan(volume.scanPath) }
                            .controlSize(.small)
                            .disabled(storage.isScanning)
                    }
                    Meter(used, color: Tint.load(used).strong, height: 6)
                    Text("\(volume.used.decimal) used of \(volume.total.decimal) · \(volume.available.decimal) free")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
        }
        .frame(width: 300)
    }

    // MARK: Scan area

    @ViewBuilder
    private var scanArea: some View {
        switch storage.phase {
        case .idle:
            EmptyState(
                symbol: "square.grid.3x3.square",
                title: "Pick a volume or folder",
                detail: "Procmon measures every file and draws the result as boxes you can click into. "
                    + "macOS asks before it lets any app read folders like Documents and Desktop; "
                    + "Full Disk Access skips those questions."
            ) {
                HStack(spacing: 8) {
                    Button("Scan Home") { storage.scan(NSHomeDirectory()) }
                    Button("Full Disk Access…") { Finder.openFullDiskAccessSettings() }
                }
            }
        case .scanning(let root, let progress):
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("Scanning \(root)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(progress.files.formatted()) files · \(progress.bytes.decimal)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                    Button("Cancel") { storage.cancel() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .failed(let root, let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't scan \(root)", detail: message) {
                Button("Try Again") { storage.rescan() }
            }
        case .ready:
            if let browser = storage.browser {
                BrowserView(browser: browser, hovered: $hovered)
            }
        }
    }
}

/// Navigation, the map or list, and actions over a finished scan.
private struct BrowserView: View {
    let browser: StorageModel.Browser
    @Binding var hovered: NodeID?
    @Environment(AppModel.self) private var model

    private var tree: FileTree { browser.tree }
    /// The hovered node, if it is still part of this tree.
    private var hoveredNode: NodeID? { hovered.flatMap { tree.contains($0) ? $0 : nil } }

    var body: some View {
        header
        Group {
            switch browser.mode {
            case .map:
                TreemapView(
                    tree: tree,
                    current: browser.current,
                    revision: browser.revision,
                    selected: browser.selected,
                    hovered: $hovered
                )
            case .largest:
                LargestFilesList(tree: tree, files: browser.largest)
            }
        }
        .frame(maxHeight: .infinity)
        footer
        if tree.unreadable > 0 {
            HStack(spacing: 6) {
                Image(systemName: "lock")
                Text("\(tree.unreadable) folders were skipped because macOS privacy settings protect them.")
                Button("Allow Full Disk Access…") { Finder.openFullDiskAccessSettings() }
                .buttonStyle(.link)
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryText)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Breadcrumbs(tree: tree, current: browser.current)
            Spacer(minLength: 8)
            Picker("View", selection: Binding(get: { browser.mode }, set: { model.storage.setMode($0) })) {
                ForEach(StorageModel.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                model.storage.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("Up one level")
            .disabled(tree[browser.current].parent == nil || browser.mode != .map)
            Button {
                model.storage.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Scan again")
        }
        .controlSize(.small)
    }

    private var footer: some View {
        let focus = tree[hoveredNode ?? browser.target]
        let target = browser.target
        let path = tree.path(of: target)
        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(Tint.category(focus.category).strong).frame(width: 7, height: 7)
                Text("\(tree.title(of: hoveredNode ?? browser.target)) · \(focus.size.decimal) · \(focus.files.formatted()) files")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundStyle(Palette.secondaryText)
            .frame(minWidth: 140, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 8)
            if browser.mode == .map {
                Legend()
            }
            if let path {
                Button("Reveal in Finder") { Finder.reveal(path) }
                    .controlSize(.small)
            }
            if target != .root && path != nil {
                Button("Move to Trash…", role: .destructive) { model.confirmTrash(target) }
                    .controlSize(.small)
            }
        }
    }
}

private struct Breadcrumbs: View {
    let tree: FileTree
    let current: NodeID
    @Environment(AppModel.self) private var model

    var body: some View {
        let lineage = tree.lineage(current)
        // Long paths keep the root and the last few folders.
        let shown: [NodeID?] = lineage.count > 5 ? [lineage[0], nil] + lineage.suffix(3).map { $0 } : lineage.map { $0 }
        HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.tertiaryText)
                }
                if let node {
                    Button(tree.title(of: node)) { model.storage.focus(node) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: node == current ? .semibold : .regular))
                        .foregroundStyle(node == current ? Palette.text : Palette.secondaryText)
                        .lineLimit(1)
                } else {
                    Text("…").foregroundStyle(Palette.tertiaryText)
                }
            }
        }
        .truncationMode(.middle)
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(FileCategory.legend, id: \.self) { category in
                HStack(spacing: 4) {
                    Circle().fill(Tint.category(category).strong).frame(width: 6, height: 6)
                    Text(category.label)
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Palette.secondaryText)
        .lineLimit(1)
        .fixedSize()
    }
}

/// The biggest individual files anywhere in the scan.
private struct LargestFilesList: View {
    let tree: FileTree
    let files: [NodeID]
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(files, id: \.self) { id in
                    LargestFileRow(tree: tree, id: id)
                }
            }
        }
        .overlay {
            if files.isEmpty {
                EmptyState(symbol: "doc", title: "No files", detail: "This scan did not find any files.")
            }
        }
    }
}

private struct LargestFileRow: View {
    let tree: FileTree
    let id: NodeID
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let node = tree[id]
        let path = tree.path(of: id)
        let folder = path.map { ($0 as NSString).deletingLastPathComponent }
            .map { $0.hasPrefix(tree.rootPath) ? String($0.dropFirst(tree.rootPath.count)) : $0 }
        HStack(spacing: 10) {
            Circle().fill(Tint.category(node.category).strong).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder.map { $0.isEmpty ? "/" : $0 } ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if hovering, let path {
                Button { Finder.reveal(path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                Button { model.confirmTrash(id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Move to Trash…")
            }
            Text(node.size.decimal)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(hovering ? Palette.surfaceHover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { model.storage.focus(id) }
        .help("Show in the map")
    }
}
