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
