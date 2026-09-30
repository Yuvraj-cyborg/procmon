// Top-level pages and the floating navigation bar that switches between them.

import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, memory, activity, storage, devices

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .memory: "Memory"
        case .activity: "Activity"
        case .storage: "Storage"
        case .devices: "Devices"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "Everything at a glance"
        case .memory: "RAM, swap and the apps holding it"
        case .activity: "CPU load, stuck threads and noisy processes"
        case .storage: "Volumes and what is taking up space"
        case .devices: "Connected hardware and loaded drivers"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .memory: "memorychip"
        case .activity: "waveform.path.ecg"
        case .storage: "internaldrive"
        case .devices: "cable.connector"
        }
    }

    /// ⌘1 … ⌘5.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String(Page.allCases.firstIndex(of: self)! + 1)))
    }
}

/// A pill of page tabs. The selection indicator slides between tabs.
struct NavBar: View {
    @Binding var selection: Page
    /// Icons only, for narrow windows.
    var compact = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases) { page in
                tab(page)
            }
        }
        .padding(3)
        .glassBackground(interactive: true)
    }

    private func tab(_ page: Page) -> some View {
        let selected = selection == page
        return Button {
            withAnimation(.snappy(duration: 0.3)) { selection = page }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                if !compact {
                    Text(page.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .fixedSize()
                }
            }
            .foregroundStyle(selected ? Palette.text : Palette.secondaryText)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: 28)
            .background {
                if selected {
                    Capsule()
                        .fill(Palette.surface.opacity(0.9))
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                        .overlay(Capsule().strokeBorder(Palette.border.opacity(0.8), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("\(page.title)  ⌘\(String(page.shortcut.character))")
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// App icon and name at the leading edge of the toolbar.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            Text("Procmon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Appearance and list preferences.
struct SettingsMenu: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Menu {
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(Appearance.allCases) { appearance in
                    Label(appearance.label, systemImage: appearance.symbol).tag(appearance)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Group processes by app", isOn: $preferences.groupByApp)
            Toggle("Show Apple drivers", isOn: $preferences.showAppleDrivers)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuIndicator(.hidden)
        .help("Settings")
    }
}
