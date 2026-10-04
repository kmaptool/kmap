import Foundation

/// The last `limit` events, for a reader that draws them all at once.
///
/// Reading takes a copy, so rendering never blocks a producer and a producer never waits
/// on the screen.
final class LogRing: LogSink {
    private let lock = NSLock()
    /// Up to `limit` events; once full, `oldest` is where the next one goes.
    private var events: [LogEvent] = []
    private var oldest = 0
    private let limit: Int

    init(limit: Int = 4000) { self.limit = max(1, limit) }

    /// Once full, the oldest slot is overwritten in place: the log's lock is held here,
    /// and every writer waits on it.
    func receive(_ event: LogEvent) {
        lock.lock()
        if events.count < limit {
            events.append(event)
        } else {
            events[oldest] = event
            oldest = (oldest + 1) % limit
        }
        lock.unlock()
    }

    /// Oldest first.
    func snapshot() -> [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard oldest > 0 else { return events }
        return Array(events[oldest...] + events[..<oldest])
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}
