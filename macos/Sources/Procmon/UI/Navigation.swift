// Top-level pages and the floating navigation bar that switches between them.

import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, memory, activity, graphics, storage, recovery, devices

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .memory: "Memory"
        case .activity: "Activity"
        case .graphics: "Graphics"
        case .storage: "Storage"
        case .recovery: "Recovery"
        case .devices: "Devices"
        }
    }

    var glyph: Glyph {
        switch self {
        case .overview: .overview
        case .memory: .memory
        case .activity: .activity
        case .graphics: .graphics
        case .storage: .storage
        case .recovery: .recovery
        case .devices: .devices
        }
    }

    /// ⌘1 … ⌘7.
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
            withAnimation(.snappy(duration: 0.25)) { selection = page }
        } label: {
            HStack(spacing: 6) {
                GlyphImage(page.glyph, size: 14)
                if !compact {
                    Text(page.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .fixedSize()
                }
            }
            .foregroundStyle(selected ? Palette.text : Palette.secondaryText)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: 28)
            .background {
                if selected {
                    Capsule()
                        .fill(Palette.panel.opacity(0.9))
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
    /// Icon only, for narrow windows.
    var compact = false

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
            if !compact {
                Text("Procmon")
                    .font(TextStyle.emphasis)
                    .foregroundStyle(Palette.text)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Appearance, refresh rate, list and permission settings.
struct SettingsMenu: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Menu {
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            Picker("Update", selection: $preferences.updateSpeed) {
                ForEach(UpdateSpeed.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Toggle("Group processes by app", isOn: $preferences.groupByApp)
            Toggle("Show Apple drivers", isOn: $preferences.showAppleDrivers)
            Divider()
            if Permissions.hasFullDiskAccess {
                Text("Full Disk Access is on")
            } else {
                Button("Allow Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
            }
        } label: {
            Image(nsImage: Glyph.settings.templateImage(size: 15))
        }
        .menuIndicator(.hidden)
        .help("Settings")
    }
}
