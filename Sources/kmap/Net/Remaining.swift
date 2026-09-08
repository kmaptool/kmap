import Foundation

/// How much longer a transfer has to run, from what has actually arrived.
///
/// Bytes still to come divided by the rate since the transfer began. While bytes keep
/// arriving at a steady rate the answer counts down, which an average over finished parts
/// would not.
enum Remaining {

    /// Below this there is not enough of a sample to say anything: the connections are
    /// still opening and a rate taken here swings by orders of magnitude.
    static let settlesAfter: TimeInterval = 1

    /// Seconds still to come, or nil when it cannot honestly be said yet.
    ///
    /// - Parameters:
    ///   - received: bytes down the wire so far, including what is only part-way through.
    ///   - total: bytes expected in all. Stated by the server, or estimated.
    ///   - elapsed: how long this transfer has been running.
    ///   - alreadyOnDisk: bytes resumed rather than fetched. They count towards what is
    ///     left to do but not towards the rate, which a resume would otherwise overstate.
    static func seconds(received: Int64, total: Int64, elapsed: TimeInterval,
                        alreadyOnDisk: Int64 = 0) -> Double? {
        guard elapsed > settlesAfter else { return nil }
        let fetched = Double(received - alreadyOnDisk)
        guard fetched > 0 else { return nil }
        let rate = fetched / elapsed
        let left = Double(total - received)
        guard left > 0, rate > 0 else { return nil }
        let seconds = left / rate
        return seconds.isFinite ? seconds : nil
    }
}

/// How long the rest of a job of many small parts will take, from how fast parts have
/// finished lately. The rate is taken over a trailing window rather than since the start,
/// so parts landing in batches are divided by the time between batches. Nothing is
/// reported until the window holds a real sample.
struct Pace {

    /// How far back the rate is measured. Long enough to span the gap between two batches
    /// landing, short enough to follow a link that has genuinely changed speed.
    let window: TimeInterval

    /// Nothing is said until the sample covers at least this long.
    let settlesAfter: TimeInterval

    /// And until at least this many parts have finished inside the window.
    let minimumParts: Int

    private var samples: [(at: Date, done: Int)] = []

    init(window: TimeInterval = 60, settlesAfter: TimeInterval = 20, minimumParts: Int = 8) {
        self.window = window
        self.settlesAfter = settlesAfter
        self.minimumParts = minimumParts
    }

    /// Records how many parts are finished. Called as often as the display refreshes;
    /// samples older than the window fall off the front.
    mutating func note(done: Int, at now: Date = Date()) {
        samples.append((now, done))
        let cutoff = now.addingTimeInterval(-window)
        // One sample older than the cutoff is kept: it is the far end of the window, and
        // dropping it would measure from the first sample *inside* it and shorten the span.
        if let last = samples.lastIndex(where: { $0.at < cutoff }), last > 0 {
            samples.removeFirst(last)
        }
    }

    /// Parts a second, over the window, or nil while the sample is too thin to say.
    func rate(at now: Date = Date()) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        let parts = last.done - first.done
        guard span >= settlesAfter, parts >= minimumParts else { return nil }
        let rate = Double(parts) / span
        return rate > 0 ? rate : nil
    }

    /// Seconds still to come, or nil while nothing honest can be said.
    func secondsLeft(_ remaining: Int, at now: Date = Date()) -> Double? {
        guard remaining > 0, let rate = rate(at: now) else { return nil }
        let seconds = Double(remaining) / rate
        return seconds.isFinite ? seconds : nil
    }
}
