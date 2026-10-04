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
        @Bindable var model = model
        GeometryReader { proxy in
            ScrollView {
                content.frame(height: max(proxy.size.height, 560))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // A hovered id belongs to one tree: a new scan or an edited tree
        // starts without one, since no hover-ended event arrives for it.
        .onChange(of: [storage.generation, storage.browser?.revision ?? -1]) { hovered = nil }
        .onAppear { model.cleanup.scanSoon(model.monitor) }
        .sheet(isPresented: $model.isReviewingJunk) {
            JunkReview()
        }
        .sheet(isPresented: Binding(get: { model.diskAccessRequest != nil }, set: { if !$0 { model.diskAccessRequest = nil } })) {
            DiskAccessQuestion()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            PageHeader(title: Page.storage.title) {
                Button("Scan Home") { model.scan(NSHomeDirectory()) }
                Button("Choose Folder…") { chooseFolder() }
                    .buttonStyle(.borderedProminent)
            }
            volumes
            ReclaimableLine()
            Panel(padding: Space.m, fills: true) {
                scanArea
            }
            .frame(minHeight: 300)
        }
        .frame(maxWidth: Layout.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Layout.pagePadding)
        .padding(.top, Space.m)
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
            // Picking a folder in the open panel grants access to it, so
            // there is nothing to ask first.
            MainActor.assumeIsolated { storage.scan(url.path) }
        }
    }

    // MARK: Volumes

    private var volumes: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Layout.spacing) {
                ForEach(storage.volumes) { volume in
                    volumePanel(volume)
                }
            }
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
    }

    private func volumePanel(_ volume: Volume) -> some View {
        let used = volume.used.ratio(of: volume.total)
        return Panel(padding: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(TextStyle.emphasis)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text([volume.mountPoint, volume.format].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(TextStyle.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.s)
                Button("Scan") { model.scan(volume.scanPath) }
                    .controlSize(.small)
                    .disabled(storage.isScanning)
            }
            Meter(ratio: used, height: 4)
            Text(volume.isReadOnly
                 ? "\(volume.total.decimal) · read-only"
                 : "\(volume.available.decimal) free of \(volume.total.decimal)")
                .font(TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(width: 280)
    }

    // MARK: Scan area

    @ViewBuilder
    private var scanArea: some View {
        switch storage.phase {
        case .idle:
            Placeholder(
                title: "Pick a volume or folder",
                detail: "Procmon measures every file and draws the result as boxes you can click into."
                    + (Permissions.hasFullDiskAccess ? "" : " Without Full Disk Access, Desktop, Documents, Downloads and app data are left out.")
            ) {
                Button("Scan Home") { model.scan(NSHomeDirectory()) }
                if !Permissions.hasFullDiskAccess {
                    Button("Allow Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
                }
            }
        case .scanning(let root, let progress):
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                VStack(spacing: Space.m) {
                    ProgressView().controlSize(.small)
                    Text("Scanning \(root)")
                        .font(TextStyle.emphasis)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(progress.files.formatted()) files · \(progress.bytes.decimal)")
                        .font(TextStyle.body)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                    Button("Cancel") { storage.cancel() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .failed(let root, let message):
            Placeholder(title: "Couldn't scan \(root)", detail: message) {
                Button("Try Again") { storage.rescan() }
            }
        case .ready:
            if let browser = storage.browser {
                BrowserView(browser: browser, hovered: $hovered)
            }
        }
    }
}

/// How much the clean-up rules could free, and the way to review it.
private struct ReclaimableLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleanup = model.cleanup
        HStack(spacing: Space.s) {
            switch cleanup.phase {
            case .idle:
                Text("Caches, logs and temporary files are measured shortly after launch.")
                    .foregroundStyle(Palette.tertiaryText)
            case .scanning:
                Text("Measuring caches, logs and temporary files…")
                    .foregroundStyle(Palette.secondaryText)
            case .ready, .cleaning:
                if cleanup.junkFound > .zero {
                    Text("\(cleanup.junkFound.decimal) reclaimable")
                        .foregroundStyle(Palette.text)
                        .monospacedDigit()
                    Text("in caches, logs and temporary files")
                        .foregroundStyle(Palette.secondaryText)
                    Button("Review…") { model.isReviewingJunk = true }
                        .buttonStyle(.link)
                } else {
                    Text("No caches, logs or temporary files worth deleting.")
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .font(TextStyle.body)
        .lineLimit(1)
    }
}

/// The one-time question before the first scan that would reach folders
/// macOS guards. Answering either way means it is never asked again.
private struct DiskAccessQuestion: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Allow Full Disk Access once?")
                .font(TextStyle.title)
            Text("macOS asks separately before any app reads Desktop, Documents, Downloads, iCloud Drive or other apps' data. Full Disk Access answers all of those at once, so Procmon can measure everything without a string of prompts.")
                .font(TextStyle.body)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("In System Settings, turn on Procmon under Full Disk Access, then let it reopen. Procmon only reads sizes; it never uploads anything.")
                .font(TextStyle.caption)
                .foregroundStyle(Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Scan Without Them") { model.answerDiskAccess(grant: false) }
                Button("Open System Settings") { model.answerDiskAccess(grant: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 440)
    }
}

/// Everything the clean-up rules found, grouped, with a checkbox per group
/// and per item. Nothing is deleted until the button is pressed.
private struct JunkReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<JunkKind> = []

    var body: some View {
        let cleanup = model.cleanup
        let selected = cleanup.selectedJunk.map(\.size).sum()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Reclaimable files").font(TextStyle.title)
                Text("Deleted for good, not moved to the Trash. Apps rebuild caches when they need them, and anything belonging to a running app is left alone.")
                    .font(TextStyle.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.xl)
            Divider()
            Group {
                switch cleanup.phase {
                case .idle, .scanning:
                    VStack(spacing: Space.s) {
                        ProgressView().controlSize(.small)
                        Note("Measuring…")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready, .cleaning:
                    if cleanup.groups.allSatisfy({ $0.items.isEmpty }) {
                        Note("Nothing needs cleaning.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(cleanup.groups.filter { !$0.items.isEmpty || $0.isUnreadable }) { group in
                                    groupRow(group)
                                    Divider()
                                }
                            }
                            .padding(.horizontal, Space.xl)
                        }
                    }
                }
            }
            .frame(minHeight: 260)
            Divider()
            HStack {
                Text(selected > .zero ? "\(selected.decimal) selected" : "Nothing selected")
                    .font(TextStyle.body)
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondaryText)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(cleanup.phase == .cleaning ? "Deleting…" : "Delete \(selected.decimal)") {
                    cleanup.clean(model.monitor) { message, kind in model.show(message, kind: kind) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == .zero || cleanup.phase != .ready)
            }
            .padding(Space.l)
        }
        .frame(width: 560, height: 520)
    }

    private func groupRow(_ group: JunkGroup) -> some View {
        @Bindable var cleanup = model.cleanup
        let isOn = cleanup.selectedKinds.contains(group.kind)
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Toggle(isOn: Binding(
                    get: { isOn },
                    set: { on in
                        if on { cleanup.selectedKinds.insert(group.kind) } else { cleanup.selectedKinds.remove(group.kind) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.kind.title).font(TextStyle.body).foregroundStyle(Palette.text)
                        Text(group.isUnreadable ? "macOS didn't let Procmon look inside." : group.kind.explanation)
                            .font(TextStyle.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(group.items.isEmpty)
                Spacer(minLength: Space.m)
                Text(group.size.decimal)
                    .font(TextStyle.body)
                    .monospacedDigit()
                    .foregroundStyle(isOn ? Palette.text : Palette.tertiaryText)
            }
            if !group.items.isEmpty {
                Button(expanded.contains(group.kind) ? "Hide \(Format.count(group.items.count, "item"))" : "Show \(Format.count(group.items.count, "item"))") {
                    if expanded.contains(group.kind) { expanded.remove(group.kind) } else { expanded.insert(group.kind) }
                }
                .buttonStyle(.link)
                .font(TextStyle.caption)
                .padding(.leading, 22)
            }
            if expanded.contains(group.kind) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.items.sorted { $0.size > $1.size }.prefix(200)) { item in
                        itemRow(item, enabled: isOn)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, Space.m)
    }

    private func itemRow(_ item: JunkItem, enabled: Bool) -> some View {
        @Bindable var cleanup = model.cleanup
        return HStack(spacing: Space.s) {
            Toggle(isOn: Binding(
                get: { !cleanup.excludedItems.contains(item.path) },
                set: { on in
                    if on { cleanup.excludedItems.remove(item.path) } else { cleanup.excludedItems.insert(item.path) }
                }
            )) {
                Text(item.name)
                    .font(TextStyle.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(item.path)
            Spacer(minLength: Space.s)
            Text(item.size.decimal)
                .font(TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryText)
        }
        .disabled(!enabled)
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
        let left = Int(tree.unreadable) + tree.skipped
        if left > 0 {
            HStack(spacing: Space.s) {
                GlyphImage(.lock, size: 11)
                Text("\(Format.count(left, "protected folder")) left out.")
                if !Permissions.hasFullDiskAccess {
                    Button("Allow Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
                        .buttonStyle(.link)
                }
            }
            .font(TextStyle.caption)
            .foregroundStyle(Palette.secondaryText)
        }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
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
                GlyphImage(.arrowUp, size: 12)
            }
            .help("Up one level")
            .disabled(tree[browser.current].parent == nil || browser.mode != .map)
            Button {
                model.storage.rescan()
            } label: {
                GlyphImage(.refresh, size: 12)
            }
            .help("Scan again")
        }
        .controlSize(.small)
    }

    private var footer: some View {
        let focus = tree[hoveredNode ?? browser.target]
        let target = browser.target
        let path = tree.path(of: target)
        return HStack(spacing: Space.m) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(Tint.category(focus.category).strong).frame(width: 8, height: 8)
                Text("\(tree.title(of: hoveredNode ?? browser.target)) · \(focus.size.decimal) · \(focus.files.formatted()) files")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(TextStyle.caption)
            .monospacedDigit()
            .foregroundStyle(Palette.secondaryText)
            .frame(minWidth: 140, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 8)
            if browser.mode == .map {
                Legend()
            }
            if let path {
                Button("Show in Finder") { Finder.reveal(path) }
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
                    GlyphImage(.chevron, size: 8)
                        .foregroundStyle(Palette.tertiaryText)
                }
                if let node {
                    Button(tree.title(of: node)) { model.storage.focus(node) }
                        .buttonStyle(.plain)
                        .font(node == current ? TextStyle.emphasis : TextStyle.body)
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
        HStack(spacing: Space.m) {
            ForEach(FileCategory.legend, id: \.self) { category in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Tint.category(category).strong).frame(width: 8, height: 8)
                    Text(category.label)
                }
            }
        }
        .font(TextStyle.caption)
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
                Note("This scan found no files.")
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
        HStack(spacing: Space.s) {
            RoundedRectangle(cornerRadius: 1.5).fill(Tint.category(node.category).strong).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(TextStyle.body)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder.map { $0.isEmpty ? "/" : $0 } ?? "")
                    .font(TextStyle.caption)
                    .foregroundStyle(Palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if hovering, let path {
                Button { Finder.reveal(path) } label: { GlyphImage(.folder, size: 13) }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                Button { model.confirmTrash(id) } label: { GlyphImage(.trash, size: 13) }
                    .buttonStyle(.borderless)
                    .help("Move to Trash…")
            }
            Text(node.size.decimal)
                .font(TextStyle.body)
                .monospacedDigit()
                .foregroundStyle(Palette.text)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, Space.s)
        .frame(height: 38)
        .background(hovering ? Palette.hover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { model.storage.focus(id) }
        .help("Show in the map")
    }
}
