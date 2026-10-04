// Connected hardware, and whether its drivers are working.

import SwiftUI

struct DevicesPage: View {
    /// Devices that are known but not connected are listed up to this many per group.
    static let absentShown = 3

    @Environment(AppModel.self) private var model

    var body: some View {
        PageScroll {
            PageHeader(title: Page.devices.title, detail: model.devices.inventory.map(summary)) {
                if model.devices.isLoading {
                    ProgressView().controlSize(.small)
                }
                GlyphButton(.refresh, title: "Refresh", help: "Look for hardware again") { model.devices.refresh() }
                    .disabled(model.devices.isLoading)
            }
            if let inventory = model.devices.inventory {
                problems(inventory)
                groups(inventory)
                DriverSection(drivers: inventory.drivers, showApple: Bindable(model.preferences).showAppleDrivers)
                if !inventory.errors.isEmpty {
                    Text("Couldn't read: \(inventory.errors.joined(separator: "; "))")
                        .font(TextStyle.caption)
                        .foregroundStyle(Palette.tertiaryText)
                }
            } else {
                Note("Asking the system for connected hardware…")
            }
        }
    }

    private func summary(_ inventory: Inventory) -> String {
        let thirdParty = inventory.drivers.count(where: \.isThirdParty)
        return "\(inventory.connected) connected · \(Format.count(inventory.drivers.count, "driver")), \(thirdParty) third-party"
    }

    @ViewBuilder
    private func problems(_ inventory: Inventory) -> some View {
        let faulty = inventory.devices.filter { $0.status == .faulty }
        let stuck = inventory.drivers.filter { !$0.state.isHealthy }
        if !faulty.isEmpty || !stuck.isEmpty {
            PageSection(title: "Problems", detail: "\(faulty.count + stuck.count)") {
                VStack(spacing: 0) {
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
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320), spacing: Space.section, alignment: .top)],
            alignment: .leading, spacing: Space.section
        ) {
            ForEach(groups, id: \.0) { deviceClass, devices in
                let present = devices.filter { $0.status != .available }
                let absent = devices.filter { $0.status == .available }
                PageSection(title: deviceClass.label, detail: "\(present.count) of \(devices.count)") {
                    VStack(spacing: 0) {
                        ForEach(present + absent.prefix(Self.absentShown)) { DeviceRow(device: $0) }
                    }
                    if absent.count > Self.absentShown {
                        Text("and \(absent.count - Self.absentShown) more not connected")
                            .font(TextStyle.caption)
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
        let level: Level = device.status == .faulty ? .critical : .normal
        return ItemRow(title: device.name, detail: detail, dimmed: device.status == .available) {
            Text(device.status.label)
                .foregroundStyle(level == .normal ? Palette.secondaryText : level.color)
        }
    }
}

private struct DriverRow: View {
    let driver: Driver

    var body: some View {
        var detail = driver.kind.label
        if driver.name != nil { detail += " · \(driver.bundleID)" }
        if let version = driver.version { detail += " · \(version)" }
        return ItemRow(title: driver.displayName, detail: detail, dimmed: false) {
            Text(driver.state.label)
                .foregroundStyle(driver.state.isHealthy ? Palette.tertiaryText : Level.warning.color)
        }
    }
}

private struct ItemRow<Trailing: View>: View {
    let title: String
    let detail: String
    let dimmed: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TextStyle.body)
                    .foregroundStyle(dimmed ? Palette.secondaryText : Palette.text)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(TextStyle.caption)
                        .foregroundStyle(dimmed ? Palette.tertiaryText : Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.s)
            trailing.font(TextStyle.caption)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separator).frame(height: 0.5).opacity(0.6)
        }
    }
}

private struct DriverSection: View {
    let drivers: [Driver]
    @Binding var showApple: Bool

    var body: some View {
        let shown = drivers
            .filter { showApple || $0.isThirdParty }
            .sorted { lhs, rhs in
                (lhs.state.isHealthy ? 1 : 0, lhs.isThirdParty ? 0 : 1, lhs.displayName.lowercased())
                    < (rhs.state.isHealthy ? 1 : 0, rhs.isThirdParty ? 0 : 1, rhs.displayName.lowercased())
            }
        PageSection(title: "Drivers and extensions", detail: "\(shown.count)") {
            Toggle("Include Apple's", isOn: $showApple)
                .toggleStyle(.checkbox)
                .font(TextStyle.caption)
                .fixedSize()
        } content: {
            if shown.isEmpty {
                Note("No third-party drivers are loaded.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { DriverRow(driver: $0) }
                }
            }
        }
    }
}
