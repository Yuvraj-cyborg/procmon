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
        .fixture(pid: pid, name: name, memory: memory, cpu: cpu)
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
        let columns: [ProcessColumn] = [.name, .cpu, .memory, .threads, .blocked, .pid]
        #expect(ProcessColumn.fitting(columns, in: 2000) == columns)
        let narrow = ProcessColumn.fitting(columns, in: 420)
        #expect(narrow.first == .name)
        #expect(narrow.contains(.cpu))
        #expect(!narrow.contains(.pid))
    }

    @Test func onlyBlockedThreadsAreShownAndColoured() {
        let calm = ProcessSample.fixture(pid: 1, name: "a")
        #expect(ProcessColumn.blocked.text(calm) == "")
        #expect(ProcessColumn.blocked.level(calm) == .normal)
        let stuck = ProcessSample.fixture(pid: 2, name: "b", blocked: 3)
        #expect(ProcessColumn.blocked.text(stuck) == "3")
        #expect(ProcessColumn.blocked.level(stuck) == .critical)
    }

    @MainActor @Test func findsOutermostAppBundle() {
        let helper = "/Applications/Helium.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        #expect(AppIcons.bundlePath(helper) == "/Applications/Helium.app")
        #expect(AppIcons.bundlePath("/usr/bin/yes") == nil)
    }

    @Test func splitsNumberFromUnit() {
        #expect(Format.split("11.4 GB") == ("11.4", "GB"))
        #expect(Format.split("42") == ("42", nil))
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
