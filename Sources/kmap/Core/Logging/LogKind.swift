import Foundation

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
