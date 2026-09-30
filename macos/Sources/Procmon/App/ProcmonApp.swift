// Entry point: one window, the menu bar and keyboard shortcuts.

import AppKit
import SwiftUI

@main
struct ProcmonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(launch: .parse(Array(CommandLine.arguments.dropFirst())))

    var body: some Scene {
        Window("Procmon", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { ProcmonCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A single-window utility: closing the window means quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    #if DEBUG
    /// `swift run` starts the bare executable, which has no bundle and so no
    /// icon; borrow the one in the repository.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleIdentifier == nil else { return }
        let icon = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../../assets/icon/procmon-512.png")
        NSApp.applicationIconImage = NSImage(contentsOf: icon)
    }
    #endif
}

private struct ProcmonCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .toolbar) {
            ForEach(Page.allCases) { page in
                Button(page.title) { model.page = page }
                    .keyboardShortcut(page.shortcut, modifiers: .command)
            }
            Divider()
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r")
            Button("Find") { model.requestSearch() }
                .keyboardShortcut("f")
            Divider()
        }
    }
}
