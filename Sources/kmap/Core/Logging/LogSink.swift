import Foundation

/// Somewhere events go.
///
/// A sink is handed every event that clears the log's floor, in order, from whichever
/// thread produced it, so an implementation locks whatever it keeps.
protocol LogSink: AnyObject {
    func receive(_ event: LogEvent)
}

/// Calls a closure for every event. For a reader that wants the stream itself rather than
/// a record of it -- the JSON writer, or a test.
final class LogRelay: LogSink {
    private let body: @Sendable (LogEvent) -> Void

    init(_ body: @escaping @Sendable (LogEvent) -> Void) { self.body = body }

    func receive(_ event: LogEvent) { body(event) }
}
