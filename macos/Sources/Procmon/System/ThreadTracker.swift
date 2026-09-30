// Remembers how long each thread has been in its current state, so a single
// unlucky sample never raises an alert.

struct ThreadTracker {
    static let blockedAfter = Duration.seconds(3)
    static let stoppedAfter = Duration.seconds(3)
    static let spinningAfter = Duration.seconds(10)
    static let spinningCPU = 0.9

    private struct Key: Hashable {
        let pid: PID
        let thread: ThreadID
    }

    private struct Track {
        var state: ThreadRunState
        var stateSince: ContinuousClock.Instant
        var hotSince: ContinuousClock.Instant?
        var seenAt: ContinuousClock.Instant
    }

    private var tracks: [Key: Track] = [:]

    var isEmpty: Bool { tracks.isEmpty }

    /// Updates the tracks for one process and returns the alerts it raises.
    mutating func observe(
        pid: PID,
        process: String,
        samples: [ThreadSample],
        at now: ContinuousClock.Instant
    ) -> [ThreadAlert] {
        var alerts: [ThreadAlert] = []
        for sample in samples {
            let key = Key(pid: pid, thread: sample.id)
            var track = tracks[key] ?? Track(state: sample.state, stateSince: now, hotSince: nil, seenAt: now)
            track.seenAt = now
            if track.state != sample.state {
                track.state = sample.state
                track.stateSince = now
            }
            if sample.cpu.value >= Self.spinningCPU {
                track.hotSince = track.hotSince ?? now
            } else {
                track.hotSince = nil
            }
            tracks[key] = track

            let inState = now - track.stateSince
            let finding: (ThreadAlertKind, Duration)? = switch track.state {
            case .uninterruptible where inState >= Self.blockedAfter: (.blocked, inState)
            case .stopped where inState >= Self.stoppedAfter: (.stopped, inState)
            default: track.hotSince
                .map { now - $0 }
                .flatMap { $0 >= Self.spinningAfter ? (.spinning(cpu: sample.cpu), $0) : nil }
            }
            if let (kind, duration) = finding {
                alerts.append(ThreadAlert(
                    pid: pid,
                    process: process,
                    thread: sample.id,
                    threadName: sample.name,
                    kind: kind,
                    duration: duration
                ))
            }
        }
        return alerts
    }

    /// Drops threads that were not seen in the pass that just finished.
    mutating func finishPass(at now: ContinuousClock.Instant) {
        tracks = tracks.filter { $0.value.seenAt == now }
    }
}
