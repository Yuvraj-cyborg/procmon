import AppKit
import SwiftUI
import Testing
@testable import Procmon

/// Renders pages with live data into PNGs, for checking layouts without a
/// screen: `PROCMON_SNAPSHOT=/tmp/shots swift test --filter PageRenderTests`.
/// `PROCMON_PAGES=graphics,overview` limits which pages are drawn.
@MainActor
@Suite(.enabled(if: Foundation.ProcessInfo.processInfo.environment["PROCMON_SNAPSHOT"] != nil), .serialized)
struct PageRenderTests {
    private let folder = URL(fileURLWithPath: Foundation.ProcessInfo.processInfo.environment["PROCMON_SNAPSHOT"] ?? "/tmp")

    private var pages: [Page] {
        let names = Foundation.ProcessInfo.processInfo.environment["PROCMON_PAGES"]?.split(separator: ",").map(String.init)
        return names.map { $0.compactMap(Page.init(rawValue:)) } ?? Page.allCases
    }

    @Test func renderPages() async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(launch: .parse([]))
        // Two samples give the charts something to draw and rates a baseline.
        // Sleeping, not spinning the run loop, lets the sampler's results in.
        for _ in 0..<200 where model.monitor.samples < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        // `PROCMON_BENCH=1` draws the Graphics page with a finished benchmark.
        if Foundation.ProcessInfo.processInfo.environment["PROCMON_BENCH"] != nil {
            model.graphics.runQuick()
            for _ in 0..<600 where model.graphics.isRunning {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        for page in pages {
            model.page = page
            if page == .recovery {
                try await renderRecovery(model)
                continue
            }
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = folder.appendingPathComponent("\(page.rawValue)-\(suffix).png")
                try await render(PageSnapshot(page: page).environment(model), appearance: appearance, to: url)
            }
        }
    }

    /// The disk list, then the results of scanning `PROCMON_RECOVER_IMAGE`.
    private func renderRecovery(_ model: AppModel) async throws {
        for _ in 0..<40 where model.recovery.disks.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await render(PageSnapshot(page: .recovery).environment(model), appearance: .aqua, to: folder.appendingPathComponent("recovery-disks.png"))
        guard let image = Foundation.ProcessInfo.processInfo.environment["PROCMON_RECOVER_IMAGE"] else { return }
        model.recovery.scanImage(URL(fileURLWithPath: image))
        for _ in 0..<600 where model.recovery.phase != .finished {
            try await Task.sleep(for: .milliseconds(50))
        }
        model.recovery.hideSmall = false
        for file in model.recovery.visible.prefix(3) {
            model.recovery.selection.insert(file.id)
        }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(PageSnapshot(page: .recovery).environment(model), appearance: appearance,
                             to: folder.appendingPathComponent("recovery-results-\(suffix).png"), settle: 40)
        }
    }

    /// Lets the main run loop run layout passes and display.
    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func render(_ view: some View, appearance: NSAppearance.Name, to url: URL, settle: Int = 15) async throws {
        let size = NSSize(width: 1200, height: 900)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        for _ in 0..<settle {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            spin(0.02)
            try await Task.sleep(for: .milliseconds(30))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
    }
}

/// A page on the canvas, as the window shows it below the toolbar.
private struct PageSnapshot: View {
    let page: Page

    var body: some View {
        Group {
            switch page {
            case .overview: OverviewPage()
            case .memory: MemoryPage()
            case .activity: ActivityPage()
            case .graphics: GraphicsPage()
            case .storage: StoragePage()
            case .recovery: RecoveryPage()
            case .devices: DevicesPage()
            }
        }
        .background(Palette.canvas)
    }
}
