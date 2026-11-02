import Foundation

/// A thread-safe counter, for progress incremented from concurrent tasks. `count` is
/// reached only under `lock`, which is what `@unchecked Sendable` stands on.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// Counts 1 more and returns the count.
    func incremented() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
