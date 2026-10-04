import Foundation

/// The last `limit` events, for a reader that draws them all at once.
///
/// Reading takes a copy, so rendering never blocks a producer and a producer never waits
/// on the screen.
final class LogRing: LogSink {
    private let lock = NSLock()
    private var events: [LogEvent] = []
    private let limit: Int

    init(limit: Int = 4000) { self.limit = limit }

    func receive(_ event: LogEvent) {
        lock.lock()
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
        lock.unlock()
    }

    func snapshot() -> [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}
