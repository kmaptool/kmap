import Foundation

/// Wall-clock per scan, appended from the scan threads under one lock. The scans run at
/// once, so the pass's own phase line reports only the longest; this keeps each one.
/// `entries` is reached only under `lock`, which is what `@unchecked Sendable` stands on.
final class ScanTimings: @unchecked Sendable {
    private var entries: [(String, Double)] = []
    private let lock = NSLock()

    /// Runs `body` and records how long it took under `what`.
    func timed(_ what: String, _ body: () -> Void) {
        let started = Date()
        body()
        note(what, seconds: Date().timeIntervalSince(started))
    }

    func note(_ what: String, seconds: Double) {
        lock.lock(); entries.append((what, seconds)); lock.unlock()
    }

    var slowestFirst: [(String, Double)] {
        lock.lock(); defer { lock.unlock() }
        return entries.sorted { $0.1 > $1.1 }
    }
}
