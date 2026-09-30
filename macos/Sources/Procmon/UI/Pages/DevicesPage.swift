// Connected hardware, and whether its drivers are working.

import SwiftUI

struct DevicesPage: View {
    /// Devices that are known but not connected are listed up to this many per group.
    static let absentShown = 3

    @Environment(AppModel.self) private var model

    var body: some View {
        PageScroll {
            PageHeader(title: Page.devices.title, subtitle: Page.devices.subtitle) {
                Button {
                    model.devices.refresh()
                } label: {
                    if model.devices.isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Refreshing")
                        }
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.devices.isLoading)
            }
            if let inventory = model.devices.inventory {
                summary(inventory)
                problems(inventory)
                groups(inventory)
                DriversCard(drivers: inventory.drivers, showApple: Bindable(model.preferences).showAppleDrivers)
                if !inventory.errors.isEmpty {
                    Text("Could not read: \(inventory.errors.joined(separator: "; "))")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiaryText)
                }
            } else {
                Card {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Asking the system for connected hardware…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
    }

    private func summary(_ inventory: Inventory) -> some View {
        let thirdParty = inventory.drivers.count(where: \.isThirdParty)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Layout.spacing)], spacing: Layout.spacing) {
            summaryCard("Connected devices", "\(inventory.connected)", symbol: "cable.connector", tint: .blue)
            summaryCard("Drivers loaded", "\(inventory.drivers.count)", symbol: "puzzlepiece.extension", tint: .purple)
            summaryCard("Third-party drivers", "\(thirdParty)", symbol: "shippingbox", tint: .orange)
            summaryCard("Problems", "\(inventory.problems)", symbol: inventory.problems == 0 ? "checkmark.seal" : "exclamationmark.triangle",
                        tint: inventory.problems == 0 ? .green : .red)
        }
    }

    private func summaryCard(_ label: String, _ value: String, symbol: String, tint: Tint) -> some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint.strong)
                    .frame(width: 34, height: 34)
                    .background(tint.fill, in: .rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Figure(value: value, size: 22)
                    Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func problems(_ inventory: Inventory) -> some View {
        let faulty = inventory.devices.filter { $0.status == .faulty }
        let stuck = inventory.drivers.filter { !$0.state.isHealthy }
        if !faulty.isEmpty || !stuck.isEmpty {
            Card {
                CardHeader(title: "Needs attention", symbol: "exclamationmark.triangle", tint: .red)
                VStack(spacing: 2) {
                    ForEach(faulty) { DeviceRow(device: $0) }
                    ForEach(stuck) { DriverRow(driver: $0) }
                }
            }
        }
    }

    private func groups(_ inventory: Inventory) -> some View {
        let groups = DeviceClass.allCases
            .map { deviceClass in (deviceClass, inventory.devices.filter { $0.deviceClass == deviceClass }) }
            .filter { !$0.1.isEmpty }
            .sorted { lhs, rhs in
                let (left, right) = (lhs.1.count { $0.status != .available }, rhs.1.count { $0.status != .available })
                return left == right ? lhs.0 < rhs.0 : left > right
            }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Layout.spacing, alignment: .top)], alignment: .leading, spacing: Layout.spacing) {
            ForEach(groups, id: \.0) { deviceClass, devices in
                let present = devices.filter { $0.status != .available }
                let absent = devices.filter { $0.status == .available }
                Card {
                    CardHeader(title: deviceClass.label, symbol: deviceClass.symbol, tint: .blue) {
                        Text("\(present.count) of \(devices.count)")
                    }
                    VStack(spacing: 2) {
                        ForEach(present + absent.prefix(Self.absentShown)) { DeviceRow(device: $0) }
                    }
                    if absent.count > Self.absentShown {
                        Text("and \(absent.count - Self.absentShown) more not connected")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.tertiaryText)
                    }
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let device: Device

    var body: some View {
        var detail = device.facts.joined(separator: " · ")
        if let driver = device.driver {
            detail += (detail.isEmpty ? "" : " · ") + "driver \(driver)"
        }
        return ItemRow(symbol: device.deviceClass.symbol, title: device.name, detail: detail, dimmed: device.status == .available) {
            HStack(spacing: 5) {
                Circle()
                    .fill(device.status == .connected ? Tint.green.strong : device.status == .faulty ? Tint.red.strong : Palette.tertiaryText)
                    .frame(width: 7, height: 7)
                Text(device.status.label)
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryText)
        }
    }
}

private struct DriverRow: View {
    let driver: Driver

    var body: some View {
        var detail = driver.kind.label
        if driver.name != nil { detail += " · \(driver.bundleID)" }
        if let version = driver.version { detail += " · v\(version)" }
        return ItemRow(symbol: "puzzlepiece.extension", title: driver.displayName, detail: detail, dimmed: false) {
            Tag(text: driver.state.label, tint: driver.state.isHealthy ? .green : .orange)
        }
    }
}

private struct ItemRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let dimmed: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.text).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 5)
        .opacity(dimmed ? 0.55 : 1)
    }
}

private struct DriversCard: View {
    let drivers: [Driver]
    @Binding var showApple: Bool

    var body: some View {
        let shown = drivers
            .filter { showApple || $0.isThirdParty }
            .sorted { lhs, rhs in
                (lhs.state.isHealthy ? 1 : 0, lhs.isThirdParty ? 0 : 1, lhs.displayName.lowercased())
                    < (rhs.state.isHealthy ? 1 : 0, rhs.isThirdParty ? 0 : 1, rhs.displayName.lowercased())
            }
        Card {
            CardHeader(title: "Drivers & extensions", symbol: "puzzlepiece.extension", tint: .purple) {
                Toggle("Include Apple", isOn: $showApple)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
            }
            if shown.isEmpty {
                Text("No third-party drivers are loaded.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { DriverRow(driver: $0) }
                }
            }
        }
    }
}
