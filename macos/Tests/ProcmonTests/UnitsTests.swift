import Testing
@testable import Procmon

@Suite struct UnitsTests {
    @Test func bytesFormatBinaryAndDecimal() {
        #expect(Bytes(512).binary == "512 B")
        #expect(Bytes(1536).binary == "1.50 KB")
        #expect(Bytes(16 * 1024 * 1024 * 1024).binary == "16.0 GB")
        #expect(Bytes(500_000_000_000).decimal == "500 GB")
    }

    @Test func bytesArithmeticSaturates() {
        #expect(Bytes(5) - Bytes(10) == .zero)
        #expect(Bytes(.max) + Bytes(1) == Bytes(.max))
    }

    @Test func ratioIsClamped() {
        #expect(Ratio(1.5).value == 1)
        #expect(Ratio(-1).value == 0)
        #expect(Ratio(.nan).value == 0)
        #expect(Bytes(5).ratio(of: .zero) == .zero)
    }

    @Test func rateIgnoresCounterReset() {
        #expect(Rate.between(10, 5, over: .seconds(1)) == .zero)
        #expect(Rate.between(10, 110, over: .seconds(1)).perSecond == 100)
        #expect(Rate.between(0, 1, over: .zero) == .zero)
    }

    @Test func durationsAreCompact() {
        #expect(Duration.seconds(42).compact == "42s")
        #expect(Duration.seconds(3 * 3600 + 120).compact == "3h 2m")
        #expect(Duration.seconds(90_000).compact == "1d 1h")
    }

    @Test func percentFormatting() {
        #expect(Percent(4.25).description == "4.2%")
        #expect(Percent(250).description == "250%")
        #expect(Percent(-3) == .zero)
    }

    @Test func machTimeConvertsTicks() {
        // Whatever the timebase, a zero tick count is zero time and time grows with ticks.
        #expect(MachTime.duration(ticks: 0) == .zero)
        #expect(MachTime.duration(ticks: 3_000) > MachTime.duration(ticks: 1_000))
    }

    @Test func historyDropsOldest() {
        var history = History<Int>(capacity: 3)
        for value in 1...5 {
            history.push(value)
        }
        #expect(history.values == [3, 4, 5])
    }
}
