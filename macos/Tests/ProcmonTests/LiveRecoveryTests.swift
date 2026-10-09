import Foundation
import Testing
@testable import Procmon

/// Scans a real disk image and saves everything found:
/// `RECOVER_IMAGE=/tmp/card.img RECOVER_OUT=/tmp/out swift test --filter LiveRecoveryTests`.
@Suite(.enabled(if: Foundation.ProcessInfo.processInfo.environment["RECOVER_IMAGE"] != nil))
struct LiveRecoveryTests {
    @Test func scanAndExportAnImage() throws {
        let environment = Foundation.ProcessInfo.processInfo.environment
        let image = environment["RECOVER_IMAGE"]!
        let source = try RawDevice(path: image)
        let scanner = RecoveryScanner(source: source)
        let clock = ContinuousClock()
        let started = clock.now
        try scanner.run()
        let files = scanner.collect().sorted { $0.offset < $1.offset }
        print("scanned \(source.size) bytes in \(clock.now - started); file systems \(scanner.fileSystems); \(files.count) files")
        for file in files {
            let format = file.format?.label ?? "?"
            print("  \(file.origin == .directory ? "named" : "found") \(format) \(file.displayName) \(file.folder ?? "") \(file.size.value) bytes at \(file.offset) \(file.condition) \(file.details.summary ?? "")")
        }
        if let out = environment["RECOVER_OUT"] {
            let report = try Exporter.export(files, from: source, sourceName: "image", to: URL(fileURLWithPath: out), progress: ExportProgress())
            print("saved \(report.saved) files, \(report.bytes.decimal), to \(report.folder.path); failures \(report.failures)")
        }
        #expect(!files.isEmpty)
    }
}
