import Foundation

/// One thing worth reporting.
///
/// `fields` carries the same facts as `text` in a form a program can read: a reader that
/// wants the tile count should not have to parse the sentence that mentions it.
struct LogEvent: Sendable {
    var text: String
    var severity: LogSeverity = .info
    var kind: LogKind = .plain
    /// The build stage it came from, where there is one.
    var stage: String?
    var fields: [String: JSONValue] = [:]
    var at: Date = Date()
    /// Position in the stream, counted from 1, so a reader can tell it missed one.
    /// Set by ``Log`` as the event goes out.
    var seq: Int = 0
}
