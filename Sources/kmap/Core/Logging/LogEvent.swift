import Foundation

/// How much a message matters.
///
/// Severity decides whether a message is shown at all; ``LogKind`` decides how. The two
/// are separate because a diagnostic and a heading are equally uninteresting to a script
/// but are drawn quite differently for a person.
enum LogSeverity: Int, Comparable, Sendable {
    /// Detail for working out why a run behaved as it did: command lines, timings, and
    /// the output of the programs kmap drives. Off unless asked for.
    case debug
    /// What the run is doing, in the words the user thinks in.
    case info
    /// The run continues, but something about it is not what was asked for.
    case warn
    /// The run cannot do what it was asked to do.
    case error

    static func < (a: LogSeverity, b: LogSeverity) -> Bool { a.rawValue < b.rawValue }

    var name: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        }
    }
}

/// What a message is, which is what a renderer marks it with.
enum LogKind: String, Sendable {
    /// An ordinary line.
    case plain
    /// A piece of work starting.
    case step
    /// A piece of work that finished as it should.
    case ok
    /// A line as another program wrote it, passed through unchanged.
    case output
}

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
