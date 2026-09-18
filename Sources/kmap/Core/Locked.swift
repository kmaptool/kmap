import Foundation

/// A value behind a lock, for state that several threads share and no actor can own:
/// what a delegate callback writes and an awaiting task reads.
///
/// The one place such state says `@unchecked Sendable`. The promise it makes is kept here:
/// the value is reached only through `withLock`, and never escapes it by reference.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Synchronous on purpose: an `NSLock` may not be held across a suspension.
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
