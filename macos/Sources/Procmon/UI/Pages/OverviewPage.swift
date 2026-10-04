// A grid of everything Procmon watches. Each panel opens its page.
//
// Every panel has the same shape: a name, the one number it exists for, a
// line of context, and a chart or short list anchored to the bottom edge.

import SwiftUI

struct OverviewPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScroll {
            PageHeader(title: Page.overview.title, detail: systemLine)
            if let snapshot = model.monitor.latest {
                let monitor = model.monitor
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: Layout.spacing)], spacing: Layout.spacing) {
                    tile(.activity) { ProcessorTile(cpu: snapshot.cpu, history: monitor.cpuHistory) }
                    tile(.memory) { MemoryTile(memory: snapshot.memory) }
                    tile(.activity) { AttentionTile(items: AttentionItem.all(in: snapshot, runaways: model.cleanup.runaways(monitor))) }
                    tile(.activity) { GraphicsTile(gpu: snapshot.gpu, history: monitor.gpuHistory) }
                    tile(.activity) {
                        PairTile(
                            title: "Network", detail: "All interfaces",
                            first: ("Received", snapshot.network?.received ?? .zero, monitor.receivedHistory),
                            second: ("Sent", snapshot.network?.sent ?? .zero, monitor.sentHistory),
                            floor: 1024
                        )
                    }
                    tile(.activity) {
                        PairTile(
                            title: "Disk activity", detail: "Physical drives",
                            first: ("Read", snapshot.disk?.read ?? .zero, monitor.diskReadHistory),
                            second: ("Written", snapshot.disk?.written ?? .zero, monitor.diskWriteHistory),
                            floor: 1024 * 1024
                        )
                    }
                    tile(.storage) { StorageTile(volumes: model.storage.volumes) }
                    tile(.activity) { EnergyTile(energy: snapshot.energy, processes: snapshot.processes) }
                    tile(action: model.reviewJunk) {
                        ReclaimableTile(cleanup: model.cleanup, idle: model.cleanup.idleApps(monitor))
                    }
                    tile(.memory) { TopMemoryTile(apps: Array(snapshot.apps.prefix(5)), snapshot: snapshot) }
                    tile(.activity) { TopCPUTile(processes: snapshot.processes) }
                    tile(.devices) { DevicesTile(inventory: model.devices.inventory) }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .onAppear { model.cleanup.scanSoon(model.monitor) }
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
        tile(action: { withAnimation(.snappy(duration: 0.3)) { model.page = destination } }, content: content)
    }

    private func tile(action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            Panel(height: Layout.tileHeight) { content() }
        }
        .buttonStyle(PanelButtonStyle())
    }
}

/// Context under a panel's number.
private struct Caption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(TextStyle.caption)
            .monospacedDigit()
            .foregroundStyle(Palette.secondaryText)
            .lineLimit(1)
    }
}

/// The number and its context, kept together.
private struct Headline: View {
    let value: String
    var unit: String?
    var level: Level = .normal
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ValueText(value: value, unit: unit, level: level)
            Caption(caption)
        }
    }
}

/// A short list row: name on the left, value on the right.
private struct ListLine: View {
    var executable: String?
    let name: String
    let value: String
    var level: Level = .normal

    var body: some View {
        HStack(spacing: Space.s) {
            if executable != nil {
                ProcessIcon(executable: executable, size: 14)
            }
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Space.s)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(level == .normal ? Palette.secondaryText : level.color)
                .lineLimit(1)
        }
        .font(TextStyle.body)
        .foregroundStyle(Palette.text)
    }
}

// MARK: - Tiles

private struct ProcessorTile: View {
    let cpu: CPUStats
    let history: History<Double>

    var body: some View {
        PanelTitle(title: "Processor", detail: String(format: "Load %.2f", cpu.load.one))
        Headline(
            value: String(format: "%.0f", cpu.total.value * 100), unit: "%",
            level: Level.load(cpu.total),
            caption: SystemInfo.current.coreSummary
        )
        Spacer(minLength: 0)
        Sparkline(values: history.values, capacity: history.capacity, ceiling: 1)
            .frame(height: 28)
        CoreBars(cores: cpu.cores, height: 10)
    }
}

private struct MemoryTile: View {
    let memory: MemoryStats

    var body: some View {
        let used = Format.split(memory.used.binary)
        let level = Level.pressure(memory.pressure)
        PanelTitle(
            title: "Memory",
            detail: level == .normal ? nil : "\(memory.pressure.label) pressure",
            detailLevel: level
        )
        Headline(value: used.value, unit: used.unit, caption: "of \(memory.total.binary) · \(memory.used.ratio(of: memory.total).percent.description) used")
        Spacer(minLength: 0)
        CompositionBar(portions: memory.breakdown.portions, total: memory.total)
    }
}

extension MemoryBreakdown {
    /// The split Activity Monitor uses, largest share of meaning first.
    var portions: [Portion] {
        [
            Portion(id: "App", value: app),
            Portion(id: "Wired", value: wired),
            Portion(id: "Compressed", value: compressed),
            Portion(id: "Cached", value: cached),
        ]
    }
}

private struct AttentionTile: View {
    let items: [AttentionItem]

    var body: some View {
        PanelTitle(title: "Needs attention")
        if items.isEmpty {
            Headline(value: "None", caption: "No stuck threads or runaway processes.")
            Spacer(minLength: 0)
        } else {
            let worst = items.map(\.level).contains(.critical) ? Level.critical : .warning
            ValueText(value: "\(items.count)", unit: items.count == 1 ? "process" : "processes", level: worst)
            Spacer(minLength: 0)
            VStack(spacing: 5) {
                ForEach(items.prefix(3)) { item in
                    ListLine(name: item.name, value: item.headline, level: item.level)
                }
            }
        }
    }
}

private struct GraphicsTile: View {
    let gpu: GPUStats?
    let history: History<Double>

    var body: some View {
        PanelTitle(title: "Graphics")
        Headline(
            value: gpu.map { String(format: "%.0f", $0.utilization.value * 100) } ?? "–", unit: "%",
            caption: gpu?.name ?? "No GPU statistics"
        )
        Spacer(minLength: 0)
        Sparkline(values: history.values, capacity: history.capacity, ceiling: 1)
            .frame(height: 40)
    }
}

/// Two rates drawn against one scale: the first dark, the second light,
/// each named where its line is described.
private struct PairTile: View {
    let title: String
    let detail: String
    let first: (label: String, rate: Throughput, history: History<Double>)
    let second: (label: String, rate: Throughput, history: History<Double>)
    /// Smallest top of the scale, so noise does not fill the chart.
    let floor: Double

    private static let secondColor = Palette.tertiaryText

    var body: some View {
        let value = Format.split(first.rate.description)
        let ceiling = max(first.history.values.max() ?? 0, second.history.values.max() ?? 0, floor)
        PanelTitle(title: title, detail: detail)
        VStack(alignment: .leading, spacing: 2) {
            ValueText(value: value.value, unit: value.unit)
            HStack(spacing: Space.m) {
                LineKey(label: first.label, color: Palette.secondaryText)
                LineKey(label: "\(second.label) \(second.rate.description)", color: Self.secondColor)
            }
        }
        Spacer(minLength: 0)
        ZStack {
            Sparkline(values: second.history.values, capacity: second.history.capacity, ceiling: ceiling, color: Self.secondColor)
            Sparkline(values: first.history.values, capacity: first.history.capacity, ceiling: ceiling)
        }
        .frame(height: 40)
    }
}

/// A short stroke in a line's colour, then its name.
private struct LineKey: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 10, height: 1.5)
            Caption(label)
        }
    }
}

private struct StorageTile: View {
    let volumes: [Volume]

    var body: some View {
        PanelTitle(title: "Storage", detail: Format.count(volumes.count, "volume"))
        if let startup = Volume.startup(in: volumes) {
            let free = Format.split(startup.available.decimal)
            let used = startup.used.ratio(of: startup.total)
            Headline(value: free.value, unit: "\(free.unit ?? "") free", caption: "of \(startup.total.decimal) on \(startup.name)")
            Spacer(minLength: 0)
            Meter(ratio: used, height: 4)
            VStack(spacing: 3) {
                ForEach(volumes.filter { $0.id != startup.id }.prefix(2)) { volume in
                    HStack {
                        Caption(volume.name)
                        Spacer()
                        Caption(volume.isReadOnly ? "Read-only" : "\(volume.available.decimal) free")
                    }
                }
            }
        } else {
            Spacer()
            Note("No volumes found.")
            Spacer()
        }
    }
}

private struct EnergyTile: View {
    let energy: EnergyStats
    let processes: [ProcessSample]

    var body: some View {
        let awake = processes.filter(\.preventsSleep)
        let hungriest = processes.max { ($0.metrics?.power ?? 0) < ($1.metrics?.power ?? 0) }
        let condition = energy.battery?.condition.flatMap { $0 == "Good" ? nil : $0 }
        PanelTitle(title: "Energy", detail: condition, detailLevel: condition == nil ? .normal : .warning)
        if let battery = energy.battery {
            Headline(
                value: String(format: "%.0f", battery.level.value * 100), unit: "%",
                level: battery.level.value < 0.1 && !battery.onPower ? .critical : .normal,
                caption: battery.summary
            )
        } else {
            let power = Format.split(Format.watts(energy.processPower))
            Headline(value: power.value, unit: power.unit, caption: "drawn by the apps Procmon can see")
        }
        Spacer(minLength: 0)
        VStack(alignment: .leading, spacing: 3) {
            if let hungriest, let power = hungriest.metrics?.power, power > 0.01 {
                Caption("Most: \(hungriest.name), \(Format.watts(power))")
            }
            Caption(awake.isEmpty ? "Nothing is keeping the Mac awake" : "Keeping it awake: \(awake.prefix(2).map(\.name).joined(separator: ", "))\(awake.count > 2 ? " +\(awake.count - 2)" : "")")
        }
    }
}

private struct ReclaimableTile: View {
    let cleanup: CleanupModel
    let idle: [IdleAppSuggestion]

    var body: some View {
        let found = Format.split(cleanup.junkFound.decimal)
        let measured = cleanup.phase == .ready || cleanup.phase == .cleaning
        PanelTitle(title: "Reclaimable", detail: cleanup.phase == .scanning ? "Measuring…" : measured ? "Review" : nil)
        Headline(
            value: measured ? found.value : "–", unit: measured ? found.unit : nil,
            caption: measured ? "in caches, logs and temporary files" : "Measured shortly after launch"
        )
        Spacer(minLength: 0)
        Caption(idle.isEmpty ? "No idle apps holding memory" : "\(Format.count(idle.count, "idle app")) holding \(idle.map(\.memory).sum().binary)")
    }
}

private struct TopMemoryTile: View {
    let apps: [AppUsage]
    let snapshot: Snapshot

    var body: some View {
        PanelTitle(title: "Top memory", detail: "by app")
        VStack(spacing: 5) {
            ForEach(apps) { app in
                let executable = app.processes.lazy.compactMap { pid in snapshot.processes.first { $0.pid == pid }?.executable }.first
                ListLine(executable: executable ?? "", name: app.name, value: app.memory.binary)
            }
        }
        Spacer(minLength: 0)
    }
}

private struct TopCPUTile: View {
    let processes: [ProcessSample]

    var body: some View {
        let top = processes.filter { ($0.cpu ?? .zero) > .zero }.sorted { ($0.cpu ?? .zero) > ($1.cpu ?? .zero) }.prefix(5)
        PanelTitle(title: "Top CPU", detail: "% of one core")
        if top.isEmpty {
            Spacer()
            Note("Everything is idle.")
            Spacer()
        } else {
            VStack(spacing: 5) {
                ForEach(top) { process in
                    ListLine(executable: process.executable ?? "", name: process.name, value: process.cpu?.description ?? "–")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DevicesTile: View {
    let inventory: Inventory?

    var body: some View {
        if let inventory {
            let problems = inventory.problems
            PanelTitle(
                title: "Devices",
                detail: problems > 0 ? "\(Format.count(problems, "problem"))" : nil,
                detailLevel: problems > 0 ? .critical : .normal
            )
            Headline(
                value: "\(inventory.connected)", unit: "connected",
                caption: "\(Format.count(inventory.drivers.count, "driver")) loaded · \(inventory.drivers.count(where: \.isThirdParty)) third-party"
            )
            Spacer(minLength: 0)
            Caption(DeviceClass.allCases.compactMap { deviceClass -> String? in
                let count = inventory.devices.count { $0.deviceClass == deviceClass && $0.status != .available }
                return count > 0 ? "\(deviceClass.shortLabel) \(count)" : nil
            }.joined(separator: " · "))
        } else {
            PanelTitle(title: "Devices")
            Spacer()
            Note("Looking for connected hardware…")
            Spacer()
        }
    }
}

extension DeviceClass {
    /// One word, for summaries.
    var shortLabel: String {
        switch self {
        case .usb: "USB"
        case .thunderbolt: "Thunderbolt"
        case .bluetooth: "Bluetooth"
        case .display: "Displays"
        case .audio: "Audio"
        case .camera: "Cameras"
        case .network: "Network"
        case .storage: "Storage"
        }
    }
}
