// A grid of everything Procmon watches. Each card opens its page.

import SwiftUI

struct OverviewPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScroll {
            PageHeader(title: "Overview", subtitle: systemLine) {
                LiveBadge()
            }
            if let snapshot = model.monitor.latest {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: Layout.spacing)], spacing: Layout.spacing) {
                    tile(.activity) { ProcessorTile(cpu: snapshot.cpu, history: model.monitor.cpuHistory) }
                    tile(.memory) { MemoryTile(memory: snapshot.memory) }
                    tile(.activity) { AttentionTile(items: AttentionItem.all(in: snapshot)) }
                    tile(.activity) { GraphicsTile(gpu: snapshot.gpu, history: model.monitor.gpuHistory) }
                    tile(.activity) {
                        NetworkTile(
                            rates: snapshot.network,
                            received: model.monitor.receivedHistory,
                            sent: model.monitor.sentHistory
                        )
                    }
                    tile(.storage) { StorageTile(volumes: model.storage.volumes) }
                    tile(.memory) { TopMemoryTile(apps: Array(snapshot.processes.groupedByApp().prefix(5)), snapshot: snapshot) }
                    tile(.activity) { TopCPUTile(processes: snapshot.processes) }
                    tile(.devices) { DevicesTile(inventory: model.devices.inventory) }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 300)
            }
        }
    }

    private var systemLine: String {
        let info = SystemInfo.current
        var parts = [model.devices.inventory?.machineName ?? info.modelIdentifier, info.chip, info.osVersion]
        if let uptime = info.uptime {
            parts.append("up \(uptime.compact)")
        }
        return parts.joined(separator: " · ")
    }

    private func tile(_ destination: Page, @ViewBuilder content: () -> some View) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { model.page = destination }
        } label: {
            Card(height: Layout.tileHeight) { content() }
        }
        .buttonStyle(CardButtonStyle())
    }
}

/// A dot that says the numbers are live. Deliberately still: a looping
/// animation would redraw the window at display rate and cost real CPU.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Tint.green.strong)
                .frame(width: 7, height: 7)
            Text("Live")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Updating live every second")
    }
}

/// Splits "11.4 GB" into its number and unit.
func splitUnit(_ formatted: String) -> (value: String, unit: String?) {
    guard let space = formatted.lastIndex(of: " ") else { return (formatted, nil) }
    return (String(formatted[..<space]), String(formatted[formatted.index(after: space)...]))
}

// MARK: - Tiles

private struct ProcessorTile: View {
    let cpu: CPUStats
    let history: History<Double>

    var body: some View {
        CardHeader(title: "Processor", symbol: "cpu", tint: .blue) {
            Text(String(format: "Load %.2f", cpu.load.one))
        }
        VStack(alignment: .leading, spacing: 2) {
            Figure(value: String(format: "%.0f", cpu.total.value * 100), unit: "%")
            Text("\(SystemInfo.current.coreSummary) · \(SystemInfo.current.chip)")
                .font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText).lineLimit(1)
        }
        Spacer(minLength: 0)
        Sparkline(values: history.values, capacity: history.capacity, color: Tint.blue.strong, ceiling: 1)
            .frame(height: 30)
        CoreBars(cores: cpu.cores, height: 12)
    }
}

private struct MemoryTile: View {
    let memory: MemoryStats

    var body: some View {
        let used = splitUnit(memory.used.binary)
        let breakdown = memory.breakdown
        CardHeader(title: "Memory", symbol: "memorychip", tint: .purple) {
            Tag(text: memory.pressure.label, tint: .pressure(memory.pressure))
        }
        VStack(alignment: .leading, spacing: 2) {
            Figure(value: used.value, unit: used.unit)
            Text("of \(memory.total.binary) · \(memory.used.ratio(of: memory.total).percent.description) used")
                .font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText)
        }
        Spacer(minLength: 0)
        Meter(segments: MemorySegments.segments(breakdown, total: memory.total), height: 8)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                legend("App", breakdown.app, .blue)
                legend("Wired", breakdown.wired, .orange)
            }
            GridRow {
                legend("Compressed", breakdown.compressed, .purple)
                legend("Cached", breakdown.cached, .green)
            }
        }
    }

    private func legend(_ label: String, _ bytes: Bytes, _ tint: Tint) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint.strong).frame(width: 6, height: 6)
            Text(label).foregroundStyle(Palette.secondaryText)
            Text(bytes.binary).foregroundStyle(Palette.text).monospacedDigit()
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

/// The Activity Monitor-style memory split, as meter segments.
enum MemorySegments {
    static func parts(_ breakdown: MemoryBreakdown) -> [(label: String, tint: Tint, bytes: Bytes)] {
        [
            ("App", .blue, breakdown.app),
            ("Wired", .orange, breakdown.wired),
            ("Compressed", .purple, breakdown.compressed),
            ("Cached files", .green, breakdown.cached),
        ]
    }

    static func segments(_ breakdown: MemoryBreakdown, total: Bytes) -> [MeterSegment] {
        parts(breakdown).map { MeterSegment(id: $0.label, ratio: $0.bytes.ratio(of: total), color: $0.tint.strong) }
    }
}

private struct AttentionTile: View {
    let items: [AttentionItem]

    var body: some View {
        CardHeader(
            title: "Needs attention",
            symbol: items.isEmpty ? "checkmark.seal" : "exclamationmark.triangle",
            tint: items.isEmpty ? .green : .red
        ) {
            if !items.isEmpty { Text(items.count == 1 ? "1 issue" : "\(items.count) issues") }
        }
        if items.isEmpty {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("All clear")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text("No stuck threads, and nothing is flooding the kernel or network.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.prefix(4)) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(item.tint.strong)
                            .frame(width: 20, height: 20)
                            .background(item.tint.fill, in: .circle)
                        Text(item.process).font(.system(size: 12)).foregroundStyle(Palette.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Tag(text: item.tag, tint: item.tint)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct GraphicsTile: View {
    let gpu: GPUStats?
    let history: History<Double>

    var body: some View {
        CardHeader(title: "Graphics", symbol: "square.stack.3d.up", tint: .pink)
        VStack(alignment: .leading, spacing: 2) {
            Figure(value: gpu.map { String(format: "%.0f", $0.utilization.value * 100) } ?? "–", unit: "%")
            Text(gpu?.name ?? "No GPU statistics")
                .font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText).lineLimit(1)
        }
        Spacer(minLength: 0)
        Sparkline(values: history.values, capacity: history.capacity, color: Tint.pink.strong, ceiling: 1)
            .frame(height: 44)
    }
}

private struct NetworkTile: View {
    let rates: InterfaceRates?
    let received: History<Double>
    let sent: History<Double>

    var body: some View {
        let down = splitUnit(rates?.received.description ?? "0 B/s")
        let ceiling = max(received.values.max() ?? 0, sent.values.max() ?? 0, 1024)
        CardHeader(title: "Network", symbol: "network", tint: .green) {
            Text("All interfaces")
        }
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tint.green.strong)
                Figure(value: down.value, unit: down.unit)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").foregroundStyle(Tint.orange.strong)
                Text("\(rates?.sent.description ?? "0 B/s") sent")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.secondaryText)
        }
        Spacer(minLength: 0)
        ZStack {
            Sparkline(values: sent.values, capacity: sent.capacity, color: Tint.orange.strong, ceiling: ceiling)
            Sparkline(values: received.values, capacity: received.capacity, color: Tint.green.strong, ceiling: ceiling)
        }
        .frame(height: 40)
    }
}

private struct StorageTile: View {
    let volumes: [Volume]

    var body: some View {
        CardHeader(title: "Storage", symbol: "internaldrive", tint: .orange) {
            Text(volumes.count == 1 ? "1 volume" : "\(volumes.count) volumes")
        }
        if let startup = Volume.startup(in: volumes) {
            let free = splitUnit(startup.available.decimal)
            let used = startup.used.ratio(of: startup.total)
            VStack(alignment: .leading, spacing: 2) {
                Figure(value: free.value, unit: "\(free.unit ?? "") free")
                Text("of \(startup.total.decimal) on \(startup.name)")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
            Meter(used, color: Tint.load(used).strong, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(volumes.filter { $0.id != startup.id }.prefix(2)) { volume in
                    HStack {
                        Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                        Text(volume.name).lineLimit(1)
                        Spacer()
                        Text("\(volume.available.decimal) free").monospacedDigit()
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryText)
        } else {
            Spacer()
            Text("No volumes").foregroundStyle(Palette.secondaryText)
            Spacer()
        }
    }
}

private struct TopMemoryTile: View {
    let apps: [AppUsage]
    let snapshot: Snapshot

    var body: some View {
        CardHeader(title: "Top memory", symbol: "chart.bar.xaxis", tint: .purple) {
            Text("by app")
        }
        VStack(spacing: 6) {
            ForEach(apps) { app in
                let executable = app.processes.lazy.compactMap { pid in snapshot.processes.first { $0.pid == pid }?.executable }.first
                HStack(spacing: 8) {
                    ProcessIcon(executable: executable, size: 15)
                    Text(app.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    UsageBar(ratio: app.memory.ratio(of: snapshot.memory.total), color: Tint.purple.strong)
                        .frame(width: 48)
                    Text(app.memory.binary)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
            }
        }
        Spacer(minLength: 0)
    }
}

private struct TopCPUTile: View {
    let processes: [ProcessSample]

    var body: some View {
        let top = processes.filter { ($0.cpu ?? .zero) > .zero }.sorted { ($0.cpu ?? .zero) > ($1.cpu ?? .zero) }.prefix(5)
        CardHeader(title: "Top CPU", symbol: "flame", tint: .red) {
            Text("% of one core")
        }
        if top.isEmpty {
            Spacer()
            Text("Everything is idle.").font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
            Spacer()
        } else {
            VStack(spacing: 6) {
                ForEach(top) { process in
                    HStack(spacing: 8) {
                        ProcessIcon(executable: process.executable, size: 15)
                        Text(process.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(process.cpu?.description ?? "–")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DevicesTile: View {
    let inventory: Inventory?

    var body: some View {
        CardHeader(title: "Devices", symbol: "cable.connector", tint: .brown) {
            if let inventory {
                if inventory.problems > 0 {
                    Tag(text: inventory.problems == 1 ? "1 needs attention" : "\(inventory.problems) need attention", tint: .red)
                } else {
                    Tag(text: "All working", tint: .green)
                }
            }
        }
        if let inventory {
            let classes = DeviceClass.allCases.compactMap { deviceClass -> (DeviceClass, Int)? in
                let count = inventory.devices.count { $0.deviceClass == deviceClass && $0.status != .available }
                return count > 0 ? (deviceClass, count) : nil
            }
            VStack(alignment: .leading, spacing: 2) {
                Figure(value: "\(inventory.connected)", unit: "connected")
                Text("\(inventory.drivers.count) drivers loaded · \(inventory.drivers.count(where: \.isThirdParty)) third-party")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(classes, id: \.0) { deviceClass, count in
                    HStack(spacing: 4) {
                        Image(systemName: deviceClass.symbol).font(.system(size: 10))
                        Text("\(count)").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.well, in: .capsule)
                    .help(deviceClass.label)
                }
            }
        } else {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for connected hardware…").font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
            }
            Spacer()
        }
    }
}

// MARK: - Attention

/// A stuck thread or a noisy process, ready to show as a row.
struct AttentionItem: Identifiable {
    let id: String
    let pid: PID
    let process: String
    let detail: String
    let symbol: String
    let tint: Tint
    let tag: String

    static func all(in snapshot: Snapshot) -> [AttentionItem] {
        let threads = snapshot.threadAlerts.map(thread)
        let noisy = snapshot.processes
            .filter { !$0.noiseReasons.isEmpty }
            .sorted { $0.intensity > $1.intensity }
            .map(noise)
        return threads + noisy
    }

    private static func thread(_ alert: ThreadAlert) -> AttentionItem {
        let thread = alert.threadName ?? "Thread \(alert.thread)"
        let (symbol, tint, what): (String, Tint, String) = switch alert.kind {
        case .blocked: ("hourglass", .orange, "in an uninterruptible wait")
        case .stopped: ("pause.fill", .gray, "suspended")
        case .spinning(let cpu): ("flame.fill", .red, "at \(cpu.percent) of a core")
        }
        return AttentionItem(
            id: "thread-\(alert.id)",
            pid: alert.pid,
            process: alert.process,
            detail: "\(thread) \(what) for \(alert.duration.compact)",
            symbol: symbol,
            tint: tint,
            tag: alert.kind.label
        )
    }

    private static func noise(_ process: ProcessSample) -> AttentionItem {
        let activity = process.activity ?? ActivityRates()
        var detail = "\(activity.syscalls) syscalls · \(activity.contextSwitches) switches · \(activity.machMessages) IPC · \(activity.idleWakeups) wakeups"
        if let network = process.network {
            detail += " · \(network.packets) packets"
        }
        return AttentionItem(
            id: "noise-\(process.pid.raw)",
            pid: process.pid,
            process: process.name,
            detail: detail,
            symbol: "bolt.fill",
            tint: .purple,
            tag: process.noiseReasons.first?.label ?? "Noisy"
        )
    }
}
