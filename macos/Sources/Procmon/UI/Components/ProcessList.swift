// Sortable process and app lists that drop their least important columns
// when the window gets narrow.

import AppKit
import SwiftUI

/// A column a process list can show. Each case knows how to title, size,
/// sort and render itself, so pages just pick a list of columns.
enum ProcessColumn: Hashable {
    case name, pid, memory, memoryShare, cpu, threads, diskRead, diskWrite
    case syscalls, contextSwitches, wakeups, received, sent, packets, runTime

    var title: String {
        switch self {
        case .name: "Process"
        case .pid: "PID"
        case .memory: "Memory"
        case .memoryShare: "Share of RAM"
        case .cpu: "CPU"
        case .threads: "Threads"
        case .diskRead: "Disk read"
        case .diskWrite: "Disk write"
        case .syscalls: "Syscalls"
        case .contextSwitches: "Switches"
        case .wakeups: "Wakeups"
        case .received: "Received"
        case .sent: "Sent"
        case .packets: "Packets"
        case .runTime: "Running for"
        }
    }

    /// Fixed width; the name column takes whatever is left.
    var width: CGFloat {
        switch self {
        case .name: 220
        case .memoryShare: 130
        case .pid, .threads: 66
        case .runTime: 92
        default: 86
        }
    }

    /// Lower-priority columns are hidden first when space runs out.
    var priority: Int {
        switch self {
        case .name: 100
        case .memory, .cpu: 90
        case .memoryShare, .syscalls: 70
        case .pid: 60
        case .received, .sent, .contextSwitches: 50
        case .wakeups, .threads: 40
        case .diskRead, .diskWrite: 30
        case .packets, .runTime: 20
        }
    }

    var isNumeric: Bool { self != .name && self != .memoryShare }

    /// The subset of `columns` that fits in `width`, in their original order.
    static func fitting(_ columns: [ProcessColumn], in width: CGFloat) -> [ProcessColumn] {
        var budget = width - ProcessColumn.name.width - 20
        var kept: Set<ProcessColumn> = [.name]
        for column in columns.filter({ $0 != .name }).sorted(by: { $0.priority > $1.priority }) where column.width <= budget {
            kept.insert(column)
            budget -= column.width
        }
        return columns.filter(kept.contains)
    }

    /// Unknown values sort below every real value.
    func key(_ process: ProcessSample) -> Double {
        let unknown = -1.0
        let activity = process.activity
        let network = process.network
        return switch self {
        case .name: 0
        case .pid: Double(process.pid.raw)
        case .memory, .memoryShare: process.memory.map { Double($0.value) } ?? unknown
        case .cpu: process.cpu?.value ?? unknown
        case .threads: process.metrics.map { Double($0.threads) } ?? unknown
        case .diskRead: process.metrics.map { Double($0.diskRead.bytes.value) } ?? unknown
        case .diskWrite: process.metrics.map { Double($0.diskWrite.bytes.value) } ?? unknown
        case .syscalls: activity?.syscalls.perSecond ?? unknown
        case .contextSwitches: activity?.contextSwitches.perSecond ?? unknown
        case .wakeups: activity?.idleWakeups.perSecond ?? unknown
        case .received: network.map { Double($0.received.bytes.value) } ?? unknown
        case .sent: network.map { Double($0.sent.bytes.value) } ?? unknown
        case .packets: network?.packets.perSecond ?? unknown
        case .runTime: process.runTime?.seconds ?? unknown
        }
    }

    func text(_ process: ProcessSample) -> String {
        let dash = "–"
        return switch self {
        case .name: process.name
        case .pid: process.pid.description
        case .memory: process.memory?.binary ?? dash
        case .memoryShare: ""
        case .cpu: process.cpu?.description ?? dash
        case .threads: process.metrics.map { "\($0.threads)" } ?? dash
        case .diskRead: process.metrics.map { $0.diskRead.bytes == .zero ? "0" : $0.diskRead.description } ?? dash
        case .diskWrite: process.metrics.map { $0.diskWrite.bytes == .zero ? "0" : $0.diskWrite.description } ?? dash
        case .syscalls: process.activity?.syscalls.description ?? dash
        case .contextSwitches: process.activity?.contextSwitches.description ?? dash
        case .wakeups: process.activity?.idleWakeups.description ?? dash
        case .received: process.network?.received.description ?? dash
        case .sent: process.network?.sent.description ?? dash
        case .packets: process.network?.packets.description ?? dash
        case .runTime: process.runTime?.compact ?? dash
        }
    }
}

struct ProcessSort: Equatable {
    var column: ProcessColumn
    var descending: Bool

    static func by(_ column: ProcessColumn) -> ProcessSort {
        ProcessSort(column: column, descending: column != .name)
    }

    /// Tapping the active column flips its direction; another column starts
    /// from its natural direction.
    func toggled(_ column: ProcessColumn) -> ProcessSort {
        column == self.column ? ProcessSort(column: column, descending: !descending) : .by(column)
    }

    func apply(_ processes: [ProcessSample]) -> [ProcessSample] {
        if column == .name {
            return processes.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return descending ? order == .orderedDescending : order == .orderedAscending
            }
        }
        let keyed = processes.map { (key: column.key($0), process: $0) }
        return keyed.sorted { lhs, rhs in
            if lhs.key != rhs.key { return descending ? lhs.key > rhs.key : lhs.key < rhs.key }
            return lhs.process.pid < rhs.process.pid
        }.map(\.process)
    }
}

/// Application icons, looked up once per bundle.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    /// The outermost `.app` bundle containing `executable`.
    static func bundlePath(_ executable: String?) -> String? {
        guard let executable, let range = executable.range(of: ".app/") else { return nil }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    /// Largest size an icon is drawn at, in points.
    private static let side: CGFloat = 40

    static func icon(for executable: String?) -> NSImage? {
        guard let bundle = bundlePath(executable) else { return nil }
        if let cached = cache[bundle] { return cached }
        let icon = thumbnail(NSWorkspace.shared.icon(forFile: bundle))
        cache[bundle] = icon
        return icon
    }

    /// Workspace icons carry every size up to 1024 px and keep the big ones
    /// decoded; one small bitmap is all a list row needs.
    private static func thumbnail(_ icon: NSImage) -> NSImage {
        let pixels = Int(side * 2)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return icon }
        // The point size must be set before the context is made from it.
        bitmap.size = NSSize(width: side, height: side)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }
}

struct ProcessIcon: View {
    let executable: String?
    var size: CGFloat = 16

    var body: some View {
        if let icon = AppIcons.icon(for: executable) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(Palette.tertiaryText)
                .frame(width: size, height: size)
                .background(Palette.well, in: .rect(cornerRadius: 4, style: .continuous))
        }
    }
}

/// Column titles; tapping one sorts by it.
private struct ColumnHeader: View {
    let columns: [ProcessColumn]
    @Binding var sort: ProcessSort
    var leadingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                Button {
                    sort = sort.toggled(column)
                } label: {
                    HStack(spacing: 3) {
                        if column.isNumeric { Spacer(minLength: 0) }
                        Text(column.title).lineLimit(1)
                        if sort.column == column {
                            Image(systemName: sort.descending ? "chevron.down" : "chevron.up")
                                .font(.system(size: 8, weight: .bold))
                        }
                        if !column.isNumeric { Spacer(minLength: 0) }
                    }
                    .foregroundStyle(sort.column == column ? Palette.text : Palette.secondaryText)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .modifier(ColumnFrame(column: column))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.leading, 10 + leadingInset)
        .padding(.trailing, 10)
        .frame(height: 28)
    }
}

private struct ColumnFrame: ViewModifier {
    let column: ProcessColumn

    func body(content: Content) -> some View {
        if column == .name {
            content.frame(minWidth: 120, maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
        } else {
            content.frame(width: column.width, alignment: column.isNumeric ? .trailing : .leading)
        }
    }
}

/// One process, one line.
struct ProcessRow: View {
    let process: ProcessSample
    let columns: [ProcessColumn]
    let totalMemory: Bytes
    var isSelected = false
    var indent: CGFloat = 0
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                cell(column).modifier(ColumnFrame(column: column))
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(Palette.text)
        .padding(.leading, 10 + indent)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(background, in: .rect(cornerRadius: 7, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if isSelected { return Palette.accent.opacity(0.12) }
        return hovering ? Palette.surfaceHover : .clear
    }

    @ViewBuilder
    private func cell(_ column: ProcessColumn) -> some View {
        switch column {
        case .name:
            HStack(spacing: 8) {
                ProcessIcon(executable: process.executable)
                Text(process.name).lineLimit(1).truncationMode(.middle)
                if process.isRestricted {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.tertiaryText)
                        .help("Owned by another user. Run Procmon with sudo to see its details.")
                }
            }
        case .memoryShare:
            let share = process.memory.map { $0.ratio(of: totalMemory) }
            HStack(spacing: 8) {
                UsageBar(ratio: share ?? .zero, color: Tint.blue.strong)
                Text(share.map { $0.percent.description } ?? "–")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.leading, 12)
        default:
            Text(column.text(process))
                .foregroundStyle(column.key(process) <= 0 ? Palette.tertiaryText : Palette.text)
                .lineLimit(1)
        }
    }
}

/// Right-click actions shared by every process row.
struct ProcessContextMenu: View {
    let process: ProcessSample
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Inspect") { model.inspect(process.pid) }
        if let executable = process.executable {
            Button("Reveal in Finder") { Finder.reveal(executable) }
        }
        Button("Copy PID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(process.pid.description, forType: .string)
        }
        Divider()
        Button("Quit") { model.quit(process.pid, name: process.name) }
        Button("Force Quit…", role: .destructive) { model.confirmForceQuit(process.pid, name: process.name) }
    }
}

/// A process table with a pinned header and its own scrolling.
struct ProcessList: View {
    let processes: [ProcessSample]
    let columns: [ProcessColumn]
    @Binding var sort: ProcessSort
    let totalMemory: Bytes
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 900

    var body: some View {
        let visible = ProcessColumn.fitting(columns, in: width)
        let rows = sort.apply(processes)
        VStack(spacing: 0) {
            ColumnHeader(columns: visible, sort: $sort, leadingInset: 24)
            Divider()
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { process in
                        ProcessRow(
                            process: process, columns: visible, totalMemory: totalMemory,
                            isSelected: model.inspectedPID == process.pid
                        )
                        .onTapGesture { model.inspect(process.pid) }
                        .contextMenu { ProcessContextMenu(process: process) }
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if rows.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No matching processes", detail: "Try a different name or PID.")
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Apps

enum AppSortColumn: Hashable {
    case name, processes, memory, cpu, threads
}

/// Processes rolled up by application; a row expands to show its processes.
struct AppList: View {
    let apps: [AppUsage]
    let processes: [PID: ProcessSample]
    let totalMemory: Bytes
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var sort = (column: AppSortColumn.memory, descending: true)
    @State private var width: CGFloat = 900

    private var showThreads: Bool { width > 720 }
    private var showShare: Bool { width > 560 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(sorted) { app in
                        appRow(app)
                        if expanded.contains(app.name) {
                            ForEach(members(of: app)) { process in
                                ProcessRow(
                                    process: process, columns: memberColumns, totalMemory: totalMemory,
                                    isSelected: model.inspectedPID == process.pid, indent: 22
                                )
                                .onTapGesture { model.inspect(process.pid) }
                                .contextMenu { ProcessContextMenu(process: process) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if apps.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No matching apps", detail: "Try a different name.")
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var memberColumns: [ProcessColumn] {
        ProcessColumn.fitting([.name, .memory, .memoryShare, .cpu, .threads, .pid], in: width - 22)
    }

    private var sorted: [AppUsage] {
        let descending = sort.descending
        return apps.sorted { lhs, rhs in
            let ordered: Bool? = switch sort.column {
            case .name: lhs.name == rhs.name ? nil : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .processes: lhs.processes.count == rhs.processes.count ? nil : lhs.processes.count < rhs.processes.count
            case .memory: lhs.memory == rhs.memory ? nil : lhs.memory < rhs.memory
            case .cpu: lhs.cpu == rhs.cpu ? nil : lhs.cpu < rhs.cpu
            case .threads: lhs.threads == rhs.threads ? nil : lhs.threads < rhs.threads
            }
            guard let ordered else { return lhs.name < rhs.name }
            return descending ? !ordered : ordered
        }
    }

    private func members(of app: AppUsage) -> [ProcessSample] {
        app.processes.compactMap { processes[$0] }.sorted { ($0.memory ?? .zero) > ($1.memory ?? .zero) }
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerButton("App", .name).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            headerButton("Processes", .processes).frame(width: 80, alignment: .trailing)
            headerButton("Memory", .memory).frame(width: 86, alignment: .trailing)
            if showShare { Text("Share of RAM").frame(width: 130, alignment: .leading).padding(.leading, 12) }
            headerButton("CPU", .cpu).frame(width: 70, alignment: .trailing)
            if showThreads { headerButton("Threads", .threads).frame(width: 70, alignment: .trailing) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Palette.secondaryText)
        .padding(.leading, 34)
        .padding(.trailing, 10)
        .frame(height: 28)
    }

    private func headerButton(_ title: String, _ column: AppSortColumn) -> some View {
        Button {
            sort = column == sort.column ? (column, !sort.descending) : (column, column != .name)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort.column == column {
                    Image(systemName: sort.descending ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(sort.column == column ? Palette.text : Palette.secondaryText)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func appRow(_ app: AppUsage) -> some View {
        let isOpen = expanded.contains(app.name)
        let share = app.memory.ratio(of: totalMemory)
        let executable = app.processes.lazy.compactMap { processes[$0]?.executable }.first { AppIcons.bundlePath($0) != nil }
        return AppRowButton {
            withAnimation(.snappy(duration: 0.2)) {
                if isOpen { expanded.remove(app.name) } else { expanded.insert(app.name) }
            }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.tertiaryText)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 24)
                HStack(spacing: 8) {
                    ProcessIcon(executable: executable ?? app.processes.first.flatMap { processes[$0]?.executable })
                    Text(app.name).lineLimit(1).truncationMode(.middle)
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                Text("\(app.processes.count)").foregroundStyle(Palette.secondaryText).frame(width: 80, alignment: .trailing)
                Text(app.memory.binary).frame(width: 86, alignment: .trailing)
                if showShare {
                    HStack(spacing: 8) {
                        UsageBar(ratio: share, color: Tint.blue.strong)
                        Text(share.percent.description).font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .frame(width: 130).padding(.leading, 12)
                }
                Text(app.cpu.description).frame(width: 70, alignment: .trailing)
                if showThreads { Text("\(app.threads)").frame(width: 70, alignment: .trailing) }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Palette.text)
        }
    }
}

/// A full-width row button with a hover highlight.
private struct AppRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.leading, 10)
                .padding(.trailing, 10)
                .frame(height: 30)
                .background(hovering ? Palette.surfaceHover : .clear, in: .rect(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A rounded filter box for process lists.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Filter by name or PID"
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.tertiaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 210, height: 28)
        .background(Palette.well, in: .capsule)
        .overlay(Capsule().strokeBorder(focus.wrappedValue ? Palette.accent.opacity(0.6) : Palette.border))
    }
}
