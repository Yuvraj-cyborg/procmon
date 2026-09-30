import Foundation
import Testing
@testable import Procmon

@Suite struct LaunchOptionsTests {
    @Test func parsesPageScanAndInspect() {
        let options = LaunchOptions.parse(["--page", "Devices", "--scan", "/tmp", "--inspect", "42"])
        #expect(options.page == .devices)
        #expect(options.scan == "/tmp")
        #expect(options.inspect == PID(42))
        #expect(options.initialPage == .devices)
    }

    @Test func picksAPageFromWhatWasAsked() {
        #expect(LaunchOptions.parse([]).initialPage == .overview)
        #expect(LaunchOptions.parse(["--scan", "~"]).initialPage == .storage)
        #expect(LaunchOptions.parse(["--inspect", "1"]).initialPage == .activity)
    }

    @Test func skipsSystemFlagsAndBadValues() {
        let options = LaunchOptions.parse(["-NSDocumentRevisionsDebugMode", "YES", "--page", "nope", "--inspect", "x"])
        #expect(options.page == nil)
        #expect(options.inspect == nil)
    }

    @Test func expandsTildeInScanPath() {
        #expect(LaunchOptions.parse(["--scan", "~/Downloads"]).scan == NSHomeDirectory() + "/Downloads")
    }
}

@Suite struct ProcessListTests {
    private func process(_ pid: Int32, _ name: String, memory: UInt64?, cpu: Double) -> ProcessSample {
        ProcessSample(
            pid: PID(pid), name: name, app: name, executable: nil, runTime: nil,
            metrics: memory.map {
                ProcessMetrics(memory: Bytes($0), cpu: Percent(cpu), threads: 1, diskRead: .zero, diskWrite: .zero, activity: nil)
            },
            network: nil
        )
    }

    @Test func sortsNumbersDescendingWithUnknownLast() {
        let rows = [process(1, "a", memory: 10, cpu: 1), process(2, "b", memory: nil, cpu: 0), process(3, "c", memory: 30, cpu: 5)]
        #expect(ProcessSort.by(.memory).apply(rows).map(\.pid.raw) == [3, 1, 2])
        #expect(ProcessSort.by(.memory).toggled(.memory).apply(rows).map(\.pid.raw) == [2, 1, 3])
    }

    @Test func sortsNamesAscendingByDefault() {
        let rows = [process(1, "zsh", memory: 1, cpu: 0), process(2, "Alfred", memory: 1, cpu: 0)]
        #expect(ProcessSort.by(.name).apply(rows).map(\.name) == ["Alfred", "zsh"])
    }

    @Test func narrowWidthsDropLowPriorityColumns() {
        let columns: [ProcessColumn] = [.name, .cpu, .syscalls, .packets, .pid]
        #expect(ProcessColumn.fitting(columns, in: 2000) == columns)
        let narrow = ProcessColumn.fitting(columns, in: 420)
        #expect(narrow.first == .name)
        #expect(narrow.contains(.cpu))
        #expect(!narrow.contains(.packets))
    }

    @MainActor @Test func findsOutermostAppBundle() {
        let helper = "/Applications/Helium.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        #expect(AppIcons.bundlePath(helper) == "/Applications/Helium.app")
        #expect(AppIcons.bundlePath("/usr/bin/yes") == nil)
    }

    @Test func splitsNumberFromUnit() {
        #expect(splitUnit("11.4 GB") == ("11.4", "GB"))
        #expect(splitUnit("42") == ("42", nil))
    }
}

@Suite struct NetworkStatusTests {
    @Test func interfacesWithAnAddressCountAsConnected() {
        let report: [String: Any] = ["SPNetworkDataType": [
            ["_name": "Wi-Fi", "interface": "en0", "hardware": "AirPort"],
            ["_name": "Thunderbolt Bridge", "interface": "bridge0", "hardware": "Ethernet"],
        ]]
        let devices = DeviceInventory.parseProfiler(report, activeInterfaces: ["en0"])
        let wifi = devices.first { $0.name == "Wi-Fi" }
        #expect(wifi?.status == .connected)
        #expect(wifi?.facts == ["en0", "Wi-Fi"])
        #expect(devices.first { $0.name == "Thunderbolt Bridge" }?.status == .available)
    }

    @Test func loopbackIsNeverReportedAsAnInterface() {
        #expect(!InterfaceProbe.activeInterfaces().contains("lo0"))
    }
}
