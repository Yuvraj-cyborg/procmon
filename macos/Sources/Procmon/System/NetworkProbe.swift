// Network traffic, per process and for the whole machine.

import Darwin
import Foundation

/// Cumulative counters for one process, as reported by `nettop`.
struct NetworkTotals: Sendable, Equatable {
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var packetsIn: UInt64 = 0
    var packetsOut: UInt64 = 0
}

/// Per-process traffic.
///
/// macOS only exposes per-process socket statistics through the private
/// NetworkStatistics framework, whose supported front-end is `nettop`. We run
/// it in one-shot CSV mode and difference the cumulative totals.
struct NetworkProbe {
    private var previous: [PID: NetworkTotals] = [:]
    private var previousAt: ContinuousClock.Instant?

    /// Rates since the last call; empty on the first call or when `nettop` fails.
    mutating func sample(at now: ContinuousClock.Instant) -> [PID: NetworkRates] {
        guard let csv = try? Subprocess.run(
            "/usr/bin/nettop",
            ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out,packets_in,packets_out"]
        ) else { return [:] }
        let totals = Self.parse(csv: csv)
        defer {
            previous = totals
            previousAt = now
        }
        guard let before = previousAt else { return [:] }
        let elapsed = now - before
        var rates: [PID: NetworkRates] = [:]
        for (pid, current) in totals {
            guard let prior = previous[pid] else { continue }
            rates[pid] = NetworkRates(
                received: .between(prior.bytesIn, current.bytesIn, over: elapsed),
                sent: .between(prior.bytesOut, current.bytesOut, over: elapsed),
                packets: .between(prior.packetsIn + prior.packetsOut, current.packetsIn + current.packetsOut, over: elapsed)
            )
        }
        return rates
    }

    /// Parses `nettop -P -L 1 -x` CSV. Columns are located by header name
    /// because `nettop` documents that their order may change.
    static func parse(csv: String) -> [PID: NetworkTotals] {
        var lines = csv.split(whereSeparator: \.isNewline).makeIterator()
        guard let header = lines.next() else { return [:] }
        let columns = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        func index(_ name: String) -> Int? { columns.firstIndex(of: name) }
        guard let bytesIn = index("bytes_in"), let bytesOut = index("bytes_out") else { return [:] }
        let (packetsIn, packetsOut) = (index("packets_in"), index("packets_out"))
        let width = columns.count

        var totals: [PID: NetworkTotals] = [:]
        while let line = lines.next() {
            // The process label (`name.pid`) may itself contain commas, so split
            // the fixed numeric columns off the right-hand side.
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= width else { continue }
            let tail = parts.suffix(width - 1)
            let label = parts.prefix(parts.count - (width - 1)).joined(separator: ",")
            let fields = [Substring(label)] + tail
            guard let dot = label.lastIndex(of: "."), let raw = Int32(label[label.index(after: dot)...]) else { continue }
            func number(_ column: Int?) -> UInt64 { column.flatMap { UInt64(fields[$0]) } ?? 0 }
            var entry = totals[PID(raw), default: NetworkTotals()]
            entry.bytesIn += number(bytesIn)
            entry.bytesOut += number(bytesOut)
            entry.packetsIn += number(packetsIn)
            entry.packetsOut += number(packetsOut)
            totals[PID(raw)] = entry
        }
        return totals
    }
}

extension InterfaceProbe {
    /// BSD names of interfaces, other than loopback, that are up and have a
    /// routable address, e.g. `en0`.
    static func activeInterfaces() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        let upAndRunning = UInt32(IFF_UP | IFF_RUNNING)
        var names = Set<String>()
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }).map(\.pointee) {
            guard let address = entry.ifa_addr,
                  entry.ifa_flags & upAndRunning == upAndRunning,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                // 169.254/16 is self-assigned: the link is up but nothing answered.
                if UInt32(bigEndian: ipv4) >> 16 != 0xA9FE {
                    names.insert(String(cString: entry.ifa_name))
                }
            case AF_INET6:
                let first = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr.__u6_addr.__u6_addr8 }
                // fe80::/10 is link-local and exists on every interface that is up.
                if !(first.0 == 0xFE && first.1 & 0xC0 == 0x80) {
                    names.insert(String(cString: entry.ifa_name))
                }
            default:
                continue
            }
        }
        return names
    }
}

/// Whole-machine traffic from the kernel's 64-bit interface counters.
struct InterfaceProbe {
    private var previous: (received: UInt64, sent: UInt64)?
    private var previousAt: ContinuousClock.Instant?

    mutating func sample(at now: ContinuousClock.Instant) -> InterfaceRates? {
        guard let totals = Self.totals() else { return nil }
        defer {
            previous = totals
            previousAt = now
        }
        guard let previous, let previousAt else { return nil }
        let elapsed = now - previousAt
        return InterfaceRates(
            received: .between(previous.received, totals.received, over: elapsed),
            sent: .between(previous.sent, totals.sent, over: elapsed)
        )
    }

    /// Sums `NET_RT_IFLIST2` counters over every interface except loopback.
    static func totals() -> (received: UInt64, sent: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= size {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if Int32(message.ifm_data.ifi_type) != IFT_LOOP {
                        received &+= message.ifm_data.ifi_ibytes
                        sent &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }
}
