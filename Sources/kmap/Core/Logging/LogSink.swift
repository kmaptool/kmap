import Foundation

/// Somewhere events go.
///
/// A sink is handed every event that clears the log's floor, in order, from whichever
/// thread produced it, so an implementation locks whatever it keeps.
protocol LogSink: AnyObject {
    func receive(_ event: LogEvent)
}

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

/// Mirrors events to a file as they arrive, so a finished run leaves a readable record.
///
/// `KMAP_LOG_TIME` puts seconds since the file was opened in front of every line.
final class LogFile: LogSink {
    private let lock = NSLock()
    private var handle: FileHandle?
    private let born = Date()
    private static let stamped = ProcessInfo.processInfo.environment["KMAP_LOG_TIME"] != nil

    init?(at url: URL) {
        Paths.ensure(url.deletingLastPathComponent())
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
    }

    deinit { try? handle?.close() }

    func receive(_ event: LogEvent) {
        let stamp = Self.stamped
            ? String(format: "%8.2f ", event.at.timeIntervalSince(born)) : ""
        guard let data = (stamp + event.text + "\n").data(using: .utf8) else { return }
        lock.lock()
        try? handle?.write(contentsOf: data)
        lock.unlock()
    }
}

/// Calls a closure for every event. For a reader that wants the stream itself rather than
/// a record of it -- the JSON writer, or a test.
final class LogRelay: LogSink {
    private let body: @Sendable (LogEvent) -> Void

    init(_ body: @escaping @Sendable (LogEvent) -> Void) { self.body = body }

    func receive(_ event: LogEvent) { body(event) }
}
