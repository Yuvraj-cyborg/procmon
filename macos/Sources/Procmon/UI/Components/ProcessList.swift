// Sortable process and app lists that drop their least important columns
// when the window gets narrow.

import AppKit
import SwiftUI

/// A column a process list can show. Each case knows how to title, size,
/// sort and render itself, so pages just pick a list of columns.
enum ProcessColumn: String, Hashable {
    case name, pid, memory, memoryShare, cpu, threads, blocked, gpu, gpuTime

    var title: String {
        switch self {
        case .name: "Process"
        case .pid: "PID"
        case .memory: "Memory"
        case .memoryShare: "Share of RAM"
        case .cpu: "CPU"
        case .threads: "Threads"
        case .blocked: "Blocked"
        case .gpu: "GPU"
        case .gpuTime: "GPU time"
        }
    }

    /// Fixed width; the name column takes whatever is left.
    var width: CGFloat {
        switch self {
        case .name: 220
        case .memoryShare: 120
        case .pid, .threads, .blocked: 64
        case .memory, .cpu, .gpu: 80
        case .gpuTime: 96
        }
    }

    /// Lower-priority columns are hidden first when space runs out.
    var priority: Int {
        switch self {
        case .name: 100
        case .gpu: 95
        case .cpu, .memory: 90
        case .blocked: 80
        case .gpuTime: 70
        case .threads: 60
        case .memoryShare: 50
        case .pid: 40
        }
    }

    var isNumeric: Bool { self != .name && self != .memoryShare }
    /// Sorted alphabetically rather than by ``key(_:)``.
    var isText: Bool { self == .name }

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
        return switch self {
        case .name: 0
        case .pid: Double(process.pid.raw)
        case .memory, .memoryShare: process.memory.map { Double($0.value) } ?? unknown
        case .cpu: process.cpu?.value ?? unknown
        case .threads: process.metrics.map { Double($0.threads) } ?? unknown
        case .blocked: Double(process.blockedThreads)
        case .gpu: process.gpu?.share.value ?? unknown
        case .gpuTime: process.gpu?.total.seconds ?? unknown
        }
    }

    /// What the cell shows. Zero blocked threads is left blank: only the
    /// exceptions should catch the eye.
    func text(_ process: ProcessSample) -> String {
        let dash = "–"
        return switch self {
        case .name: process.name
        case .pid: process.pid.description
        case .memory: process.memory?.binary ?? dash
        case .memoryShare: ""
        case .cpu: process.cpu?.description ?? dash
        case .threads: process.metrics.map { "\($0.threads)" } ?? dash
        case .blocked: process.blockedThreads > 0 ? "\(process.blockedThreads)" : ""
        case .gpu: process.gpu?.share.description ?? dash
        case .gpuTime: process.gpu.map { Format.clock($0.total) } ?? dash
        }
    }

    /// Only a blocked thread is worth colour in a table.
    func level(_ process: ProcessSample) -> Level {
        self == .blocked && process.blockedThreads > 0 ? .critical : .normal
    }
}

struct ProcessSort: Equatable {
    var column: ProcessColumn
    var descending: Bool

    static func by(_ column: ProcessColumn) -> ProcessSort {
        ProcessSort(column: column, descending: !column.isText)
    }

    /// Tapping the active column flips its direction; another column starts
    /// from its natural direction.
    func toggled(_ column: ProcessColumn) -> ProcessSort {
        column == self.column ? ProcessSort(column: column, descending: !descending) : .by(column)
    }

    func apply(_ processes: [ProcessSample]) -> [ProcessSample] {
        if column.isText {
            return processes.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                if order == .orderedSame { return $0.pid < $1.pid }
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

/// Application icons, looked up once per bundle and kept small.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    /// Largest size an icon is drawn at, in points.
    private static let side: CGFloat = 40

    /// The outermost `.app` bundle containing `executable`.
    static func bundlePath(_ executable: String?) -> String? {
        guard let executable, let range = executable.range(of: ".app/") else { return nil }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    static func icon(for executable: String?) -> NSImage? {
        guard let bundle = bundlePath(executable) else { return nil }
        if let cached = cache[bundle] { return cached }
        let icon = thumbnail(NSWorkspace.shared.icon(forFile: bundle))
        cache[bundle] = icon
        return icon
    }

    /// Workspace icons carry every size up to 1024 px and keep the big ones
    /// decoded; one small bitmap is all a row needs.
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

/// An app's icon, or nothing for plain executables: an icon is data here,
/// and a placeholder would only be decoration.
struct ProcessIcon: View {
    let executable: String?
    var size: CGFloat = 16

    var body: some View {
        if let icon = AppIcons.icon(for: executable) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// A process table, sized to show as many columns as fit.
struct ProcessList: View {
    let processes: [ProcessSample]
    let columns: [ProcessColumn]
    @Binding var sort: ProcessSort
    let totalMemory: Bytes
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 900

    var body: some View {
        let rows = sort.apply(processes)
        ProcessTable(
            rows: rows,
            columns: ProcessColumn.fitting(columns, in: width),
            sort: $sort,
            totalMemory: totalMemory,
            selected: model.inspectedPID,
            actions: ProcessActions(
                inspect: { model.inspect($0) },
                quit: { model.quit($0.pid, name: $0.name) },
                forceQuit: { model.confirmForceQuit($0.pid, name: $0.name) },
                pause: { model.send(.pause, to: $0.pid, name: $0.name) },
                resume: { model.send(.resume, to: $0.pid, name: $0.name) }
            )
        )
        .overlay {
            if rows.isEmpty {
                Note("No process matches.")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Apps

enum AppSortColumn: Hashable {
    case name, processes, memory, cpu
}

/// Processes rolled up by application; a row expands to show its processes.
/// Apps the clean-up rules find idle are marked in place, with a way to quit.
struct AppList: View {
    let apps: [AppUsage]
    let processes: [PID: ProcessSample]
    let totalMemory: Bytes
    /// Idle apps, by the PIDs of their processes.
    var idle: [PID: IdleAppSuggestion] = [:]
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var sort = (column: AppSortColumn.memory, descending: true)
    @State private var width: CGFloat = 900

    private var showShare: Bool { width > 560 }
    private var showCount: Bool { width > 460 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sorted) { app in
                        appRow(app)
                        if expanded.contains(app.name) {
                            ForEach(members(of: app)) { process in
                                MemberRow(process: process, totalMemory: totalMemory, isSelected: model.inspectedPID == process.pid)
                            }
                        }
                    }
                }
                .padding(.vertical, Space.xs)
            }
            .overlay {
                if apps.isEmpty { Note("No app matches.") }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var sorted: [AppUsage] {
        let descending = sort.descending
        return apps.sorted { lhs, rhs in
            let ordered: Bool? = switch sort.column {
            case .name: lhs.name == rhs.name ? nil : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .processes: lhs.processes.count == rhs.processes.count ? nil : lhs.processes.count < rhs.processes.count
            case .memory: lhs.memory == rhs.memory ? nil : lhs.memory < rhs.memory
            case .cpu: lhs.cpu == rhs.cpu ? nil : lhs.cpu < rhs.cpu
            }
            guard let ordered else { return lhs.name < rhs.name }
            return descending ? !ordered : ordered
        }
    }

    private func members(of app: AppUsage) -> [ProcessSample] {
        app.processes.compactMap { processes[$0] }.sorted { ($0.memory ?? .zero) > ($1.memory ?? .zero) }
    }

    private func idleApp(_ app: AppUsage) -> IdleAppSuggestion? {
        app.processes.lazy.compactMap { idle[$0] }.first
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerButton("App", .name).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            if showCount { headerButton("Processes", .processes).frame(width: 76, alignment: .trailing) }
            headerButton("Memory", .memory).frame(width: 84, alignment: .trailing)
            if showShare {
                Text("Share of RAM").frame(width: 120, alignment: .leading).padding(.leading, Space.l)
            }
            headerButton("CPU", .cpu).frame(width: 64, alignment: .trailing)
        }
        .font(TextStyle.caption)
        .foregroundStyle(Palette.secondaryText)
        .padding(.leading, 38)
        .padding(.trailing, Space.m)
        .frame(height: 26)
    }

    private func headerButton(_ title: String, _ column: AppSortColumn) -> some View {
        Button {
            sort = column == sort.column ? (column, !sort.descending) : (column, column != .name)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort.column == column {
                    Text(sort.descending ? "↓" : "↑")
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
        let idleApp = idleApp(app)
        return HoverRow { hovering in
            HStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if isOpen { expanded.remove(app.name) } else { expanded.insert(app.name) }
                    }
                } label: {
                    GlyphImage(.chevron, size: 10)
                        .foregroundStyle(Palette.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 26, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Hide processes" : "Show processes")
                HStack(spacing: Space.s) {
                    ProcessIcon(executable: executable)
                    Text(app.name).lineLimit(1).truncationMode(.middle)
                    if let idleApp {
                        Text("idle").font(TextStyle.caption).foregroundStyle(Palette.tertiaryText)
                        if hovering {
                            Button("Quit") { model.quitApp(idleApp) }
                                .controlSize(.small)
                                .help("Ask \(idleApp.name) to quit; it can save first")
                        }
                    }
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                if showCount {
                    Text("\(app.processes.count)").foregroundStyle(Palette.secondaryText).frame(width: 76, alignment: .trailing)
                }
                Text(app.memory.binary).frame(width: 84, alignment: .trailing)
                if showShare {
                    HStack(spacing: Space.s) {
                        Meter(ratio: share, height: 3, warns: false)
                        Text(share.percent.description)
                            .font(TextStyle.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(width: 120).padding(.leading, Space.l)
                }
                Text(app.cpu.description).frame(width: 64, alignment: .trailing)
            }
            .font(TextStyle.body)
            .monospacedDigit()
            .foregroundStyle(Palette.text)
        }
    }
}

/// One process of an expanded app.
private struct MemberRow: View {
    let process: ProcessSample
    let totalMemory: Bytes
    let isSelected: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HoverRow(isSelected: isSelected) { _ in
            HStack(spacing: 0) {
                Text(process.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                Text(process.pid.description).foregroundStyle(Palette.tertiaryText).frame(width: 76, alignment: .trailing)
                Text(process.memory?.binary ?? "–").frame(width: 84, alignment: .trailing)
                Spacer().frame(width: 136)
                Text(process.cpu?.description ?? "–").frame(width: 64, alignment: .trailing)
            }
            .font(TextStyle.body)
            .monospacedDigit()
            .padding(.leading, 50)
        }
        .onTapGesture { model.inspect(process.pid) }
        .contextMenu { ProcessContextMenu(process: process) }
    }
}

/// A full-width row with a quiet hover and selection highlight.
struct HoverRow<Content: View>: View {
    var isSelected = false
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .padding(.trailing, Space.m)
            .frame(height: 30)
            .background(
                isSelected ? Palette.accent.opacity(0.14) : hovering ? Palette.hover : .clear,
                in: .rect(cornerRadius: 6, style: .continuous)
            )
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}

/// Right-click actions for a process.
struct ProcessContextMenu: View {
    let process: ProcessSample
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Inspect") { model.inspect(process.pid) }
        if let executable = process.executable {
            Button("Show in Finder") { Finder.reveal(executable) }
        }
        Divider()
        Button("Pause") { model.send(.pause, to: process.pid, name: process.name) }
        Button("Resume") { model.send(.resume, to: process.pid, name: process.name) }
        Divider()
        Button("Quit") { model.quit(process.pid, name: process.name) }
        Button("Force Quit…", role: .destructive) { model.confirmForceQuit(process.pid, name: process.name) }
    }
}

/// A filter box for lists.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Filter by name or PID"
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            GlyphImage(.search, size: 12)
                .foregroundStyle(Palette.tertiaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(TextStyle.body)
                .focused(focus)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    GlyphImage(.close, size: 10).foregroundStyle(Palette.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 150, idealWidth: 220, maxWidth: 240, minHeight: 26, maxHeight: 26)
        .background(Palette.panel, in: .rect(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focus.wrappedValue ? Palette.accent.opacity(0.7) : Palette.separator, lineWidth: 1)
        )
    }
}
