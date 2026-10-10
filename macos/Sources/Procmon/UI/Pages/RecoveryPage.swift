// Bring back deleted photos, videos and documents from a card or drive:
// pick the disk, watch what turns up, choose what to keep, save it elsewhere.

import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct RecoveryPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recovery = model.recovery
        Group {
            switch recovery.phase {
            case .choosing:
                DiskChooser()
            case .opening:
                PageScroll {
                    PageHeader(title: Page.recovery.title, detail: recovery.sourceName)
                    Placeholder(
                        title: "Opening “\(recovery.sourceName)”…",
                        detail: "macOS asks for an administrator's password so Procmon can read the disk directly, block by block. Procmon only reads it."
                    ) {
                        ProgressView().controlSize(.small)
                    }
                    .frame(minHeight: 360)
                }
            case .failed(let message):
                PageScroll {
                    PageHeader(title: Page.recovery.title, detail: recovery.sourceName)
                    Placeholder(title: "Couldn't read “\(recovery.sourceName)”", detail: message) {
                        Button("Back to Disks") { recovery.reset() }
                    }
                    .frame(minHeight: 360)
                }
            case .scanning, .finished:
                ResultsView()
            }
        }
    }
}

// MARK: - Choosing a disk

private struct DiskChooser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recovery = model.recovery
        let external = recovery.disks.filter(\.isExternal)
        let images = recovery.disks.filter(\.isDiskImage)
        let builtIn = recovery.disks.filter(\.isInternal)
        PageScroll {
            PageHeader(title: Page.recovery.title, detail: "Deleted photos, videos and documents") {
                GlyphButton(.refresh, title: "Refresh", help: "Look for disks again") { recovery.refreshDisks() }
                Button("Open Disk Image…") { openImage() }
            }
            Text("Choose the card or drive the files were on. Procmon reads it block by block without changing anything, shows every photo, video, song and document it can find, and copies the ones you pick to another disk. Until then, use that disk as little as possible: anything new written to it can land where deleted files were.")
                .font(TextStyle.body)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720, alignment: .leading)
            PageSection(title: "Memory cards and drives", detail: external.isEmpty ? nil : "\(external.count)") {
                if external.isEmpty {
                    Note("Insert the memory card or connect the drive the files were on. It appears here, even if macOS can't open it.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(external) { DiskRow(disk: $0, prominent: true) }
                    }
                }
            }
            if !images.isEmpty {
                PageSection(title: "Disk images", detail: "\(images.count)") {
                    VStack(spacing: 0) {
                        ForEach(images) { DiskRow(disk: $0, prominent: false) }
                    }
                }
            }
            if !builtIn.isEmpty {
                PageSection(title: "This Mac") {
                    Note("Files deleted from this Mac's own disk rarely come back: its SSD erases freed space within minutes, and everything on it is encrypted. Time Machine and iCloud are better places to look.")
                    VStack(spacing: 0) {
                        ForEach(builtIn) { DiskRow(disk: $0, prominent: false) }
                    }
                }
            }
        }
    }

    private func openImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a disk image or a copy of a card made with dd (.img, .bin, .iso, .dd)."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { model.recovery.scanImage(url) }
        }
    }
}

private struct DiskRow: View {
    let disk: RecoveryDisk
    let prominent: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.m) {
            GlyphImage(.storage, size: 18)
                .foregroundStyle(prominent ? Palette.text : Palette.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.name)
                    .font(TextStyle.body)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(disk.summary)
                    .font(TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.m)
            if prominent {
                Button("Scan") { model.recovery.scan(disk) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Scan") { model.recovery.scan(disk) }
            }
        }
        .padding(.vertical, Space.s)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separator).frame(height: 0.5).opacity(0.6)
        }
    }
}

// MARK: - Results

private struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var previewing: FoundFile?

    var body: some View {
        let recovery = model.recovery
        VStack(alignment: .leading, spacing: Layout.spacing) {
            PageHeader(title: Page.recovery.title, detail: recovery.sourceName) {
                if recovery.phase == .scanning {
                    Button("Stop") { recovery.stop() }
                } else {
                    Button("Scan Another Disk") { recovery.reset() }
                }
            }
            ScanStatus()
            FilterBar()
            Panel(padding: 0, fills: true) {
                ResultsGrid(preview: { previewing = $0 })
            }
            .frame(minHeight: 260)
            SaveBar()
        }
        .frame(maxWidth: Layout.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Layout.pagePadding)
        .padding(.top, Space.m)
        .padding(.bottom, Layout.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $previewing) { file in
            PreviewSheet(file: file)
        }
    }
}

/// How far the scan has come, how fast, and what it has found.
private struct ScanStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recovery = model.recovery
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(alignment: .leading, spacing: Space.s) {
                if let progress = recovery.progress {
                    let fraction = progress.total > .zero ? progress.scanned.ratio(of: progress.total) : .zero
                    if recovery.phase == .scanning {
                        Meter(ratio: progress.stage == .directories ? .zero : fraction, height: 4, warns: false)
                    }
                    Text(line(progress, fraction: fraction, now: context.date))
                        .font(TextStyle.body)
                        .monospacedDigit()
                        .foregroundStyle(Palette.text)
                    if progress.unreadable > .zero {
                        Text("\(progress.unreadable.decimal) of the disk couldn't be read. It may be failing: save what you need soon, and don't scan it again more than you must.")
                            .font(TextStyle.caption)
                            .foregroundStyle(Level.warning.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(foundLine)
                    .font(TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }

    private func line(_ progress: RecoveryProgress, fraction: Ratio, now: Date) -> String {
        let recovery = model.recovery
        let elapsed = max(0, (recovery.finishedAt ?? now).timeIntervalSince(recovery.startedAt ?? now))
        if recovery.phase == .finished {
            let time = elapsed < 1 ? "under a second" : Duration.seconds(elapsed).compact
            return progress.stage == .finished
                ? "Read all \(progress.total.decimal) in \(time)."
                : "Stopped at \(fraction.percent) after \(time)."
        }
        switch progress.stage {
        case .opening, .directories:
            return "Reading the disk's folders for deleted files…"
        case .contents, .finished:
            var parts = ["\(fraction.percent)", "\(progress.scanned.decimal) of \(progress.total.decimal)"]
            if elapsed > 3, progress.scanned > .zero {
                let speed = Double(progress.scanned.value) / elapsed
                parts.append("\(Bytes(UInt64(speed)).decimal)/s")
                let left = Double(progress.total.value - progress.scanned.value) / speed
                if left.isFinite, left > 1 {
                    parts.append("about \(Duration.seconds(left).compact) left")
                }
            }
            return parts.joined(separator: " · ")
        }
    }

    private var foundLine: String {
        let counts = model.recovery.counts
        let parts = RecoveredKind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            return Format.count(count, kind.noun)
        }
        if parts.isEmpty {
            return model.recovery.phase == .scanning ? "Nothing found yet." : "Nothing was found."
        }
        return "Found " + parts.joined(separator: ", ")
    }
}

private struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var recovery = model.recovery
        HStack(spacing: Space.m) {
            Picker("Show", selection: $recovery.kind) {
                Text("All \(recovery.files.count.formatted())").tag(RecoveredKind?.none)
                ForEach(RecoveredKind.allCases.filter { (recovery.counts[$0] ?? 0) > 0 }, id: \.self) { kind in
                    Text("\(kind.label) \((recovery.counts[kind] ?? 0).formatted())").tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("Hide small files", isOn: $recovery.hideSmall)
                .toggleStyle(.checkbox)
                .help("Files under \(RecoveryModel.smallFile.decimal) found by content: mostly icons and thumbnail caches")
            Spacer(minLength: Space.s)
            Picker("Sort", selection: $recovery.sort) {
                ForEach(RecoveryModel.Sort.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .font(TextStyle.body)
        .controlSize(.small)
    }
}

private struct ResultsGrid: View {
    let preview: (FoundFile) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let files = model.recovery.visible
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 180), spacing: Space.m)], spacing: Space.m) {
                ForEach(files) { file in
                    FileTile(file: file, preview: preview)
                }
            }
            .padding(Space.m)
        }
        .overlay {
            if files.isEmpty {
                Note(model.recovery.files.isEmpty
                     ? (model.recovery.phase == .scanning ? "Files appear here as they are found." : "Nothing recoverable was found on this disk.")
                     : "Nothing matches. Small files are hidden.")
            }
        }
    }
}

/// One found file: its picture, name and size. Click to choose it;
/// double-click to look closer.
private struct FileTile: View {
    let file: FoundFile
    let preview: (FoundFile) -> Void
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        let recovery = model.recovery
        let selected = recovery.selection.contains(file.id)
        VStack(alignment: .leading, spacing: 5) {
            // The tile sets the size; the picture fills it without widening it.
            Rectangle()
                .fill(Palette.track.opacity(0.45))
                .frame(height: 104)
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } else {
                        GlyphImage(file.kind.glyph, size: 26)
                            .foregroundStyle(Palette.tertiaryText)
                    }
                }
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topLeading) {
                Checkmark(on: selected)
                    .padding(6)
                    .opacity(selected || hovering ? 1 : 0)
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = file.details.duration, duration > .zero {
                    Badge(text: Format.mediaLength(duration))
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if file.condition != .good {
                    Badge(text: file.condition == .overwritten ? "Overwritten" : "Damaged", level: .warning)
                        .padding(5)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: selected ? 2 : 0)
            }
            Text(file.displayName)
                .font(TextStyle.caption)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Text([file.size.decimal, file.details.summary ?? file.format?.label].compactMap { $0 }.joined(separator: " · "))
                .font(TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
        }
        .padding(6)
        .background(hovering ? Palette.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { preview(file) }
        .onTapGesture { toggle() }
        .contextMenu {
            Button("Preview") { preview(file) }
            Button(selected ? "Don't Recover" : "Recover This") { toggle() }
        }
        .help(help)
        .task(id: file.id) { await load() }
    }

    private var help: String {
        var lines = [file.displayName]
        if let folder = file.folder { lines.append("Was in \(folder)") }
        if let date = file.date { lines.append(date.formatted(date: .abbreviated, time: .shortened)) }
        lines.append(file.origin == .directory ? "Listed as deleted by the file system" : "Found by its contents")
        return lines.joined(separator: "\n")
    }

    private func toggle() {
        if model.recovery.selection.contains(file.id) {
            model.recovery.selection.remove(file.id)
        } else {
            model.recovery.selection.insert(file.id)
        }
    }

    private func load() async {
        let recovery = model.recovery
        if let cached = recovery.thumbnails.image(file.id) {
            image = cached
            return
        }
        guard let source = recovery.scanner?.source,
              let (picture, facts) = await RecoveryPreview.image(of: file, source: source, size: 320),
              !Task.isCancelled
        else { return }
        let loaded = NSImage(cgImage: picture, size: .zero)
        recovery.thumbnails.store(loaded, file.id)
        image = loaded
        recovery.learn(facts, about: file.id)
    }
}

private struct Checkmark: View {
    let on: Bool

    var body: some View {
        ZStack {
            Circle().fill(on ? Palette.accent : Color.black.opacity(0.35))
            Circle().strokeBorder(.white, lineWidth: 1.5)
            if on {
                Path { path in
                    path.move(to: CGPoint(x: 5.5, y: 10))
                    path.addLine(to: CGPoint(x: 8.5, y: 13))
                    path.addLine(to: CGPoint(x: 14.5, y: 7))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel(on ? "Chosen" : "Not chosen")
    }
}

private struct Badge: View {
    let text: String
    var level: Level = .normal

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((level == .normal ? Color.black.opacity(0.55) : level.color.opacity(0.9)), in: .capsule)
    }
}

/// What is chosen, and the button that saves it.
private struct SaveBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recovery = model.recovery
        let chosen = recovery.selected
        HStack(spacing: Space.m) {
            if let saving = recovery.saving {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    HStack(spacing: Space.s) {
                        ProgressView(value: saving.bytes.ratio(of: recovery.savingTotal).value)
                            .frame(width: 140)
                        Text("Saving \(saving.files) of \(chosen.count)…")
                            .monospacedDigit()
                    }
                }
            } else {
                Text(chosen.isEmpty ? "Click files to choose them, or choose all that are shown." : "\(Format.count(chosen.count, "file")) chosen · \(chosen.map(\.size).sum().decimal)")
                    .monospacedDigit()
                    .foregroundStyle(chosen.isEmpty ? Palette.secondaryText : Palette.text)
            }
            Spacer(minLength: Space.m)
            if !chosen.isEmpty {
                Button("Choose None") { recovery.selection = [] }
            }
            Button("Choose All Shown") { recovery.selectAllVisible() }
                .disabled(recovery.visible.isEmpty)
            Button(chosen.isEmpty ? "Recover…" : "Recover \(chosen.count.formatted())…") {
                RecoverySaving.chooseFolder(for: chosen, model: model)
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty || recovery.saving != nil)
        }
        .font(TextStyle.body)
    }
}

@MainActor
enum RecoverySaving {
    /// Asks where to save, refusing the disk being recovered.
    static func chooseFolder(for files: [FoundFile], model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Recover Here"
        panel.message = "Choose where to save \(Format.count(files.count, "file")). Pick a folder on a different disk from the one being recovered."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                if let problem = model.recovery.problem(savingTo: url) {
                    let alert = NSAlert()
                    alert.messageText = "Choose a folder on another disk"
                    alert.informativeText = problem
                    alert.addButton(withTitle: "Choose Another Folder…")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        chooseFolder(for: files, model: model)
                    }
                    return
                }
                model.recovery.save(files, to: url) { message, kind in model.show(message, kind: kind) }
            }
        }
    }
}

// MARK: - Preview

/// A closer look before saving: the picture, the video or song itself, and
/// what is known about the file.
private struct PreviewSheet: View {
    let file: FoundFile
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var asset: FoundFileAsset?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Palette.canvas
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(Space.m)
                } else if loading {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: Space.s) {
                        GlyphImage(file.kind.glyph, size: 40)
                            .foregroundStyle(Palette.tertiaryText)
                        Note("No preview for \(file.format?.label ?? "this kind of file"). Recover it to open it.")
                    }
                }
            }
            .frame(width: 680, height: 430)
            Divider()
            VStack(alignment: .leading, spacing: Space.m) {
                Text(file.displayName)
                    .font(TextStyle.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.xs) {
                    fact("Kind", [file.format?.label, file.kind.label].compactMap { $0 }.first ?? "")
                    fact("Size", file.size.decimal)
                    if let summary = file.details.summary { fact("Content", summary) }
                    if let date = file.date { fact("Date", date.formatted(date: .long, time: .shortened)) }
                    if let folder = file.folder { fact("Was in", folder) }
                    fact("Found", file.origin == .directory ? "Listed as deleted by the file system" : "By its contents, \(Bytes(file.offset).decimal) into the disk")
                    if file.extents.count > 1 { fact("Pieces", "\(file.extents.count)") }
                }
                if let note = conditionNote {
                    Text(note)
                        .font(TextStyle.caption)
                        .foregroundStyle(Level.warning.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Recover…") {
                        let target = file
                        dismiss()
                        RecoverySaving.chooseFolder(for: [target], model: model)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.recovery.saving != nil)
                }
            }
            .padding(Space.xl)
        }
        .frame(width: 680)
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private var conditionNote: String? {
        switch file.condition {
        case .good: nil
        case .damaged: "Its end couldn't be found, so it may be cut short or carry extra bytes. Most apps still open the part that is there."
        case .overwritten: "Its space was reused after it was deleted, so what comes back is probably not the original."
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(TextStyle.caption)
                .foregroundStyle(Palette.secondaryText)
            Text(value)
                .font(TextStyle.body)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func load() async {
        defer { loading = false }
        guard let source = model.recovery.scanner?.source else { return }
        if (file.kind == .video || file.kind == .audio), let type = RecoveryPreview.playableType(file) {
            let asset = FoundFileAsset(FoundFileReader(file, source: source), type: type)
            self.asset = asset
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset.asset))
            return
        }
        if let (picture, facts) = await RecoveryPreview.image(of: file, source: source, size: 1600) {
            image = NSImage(cgImage: picture, size: .zero)
            model.recovery.learn(facts, about: file.id)
        }
    }
}
