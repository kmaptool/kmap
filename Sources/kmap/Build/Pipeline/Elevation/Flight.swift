import Foundation

/// Byte totals across every download lane, settled and in flight both.
///
/// Thread-safe: every accessor is taken under the lock, which is what
/// `@unchecked Sendable` stands on.
final class Flight: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [ObjectIdentifier: Downloader] = [:]
    private var settled: Int64 = 0

    func joined(_ downloader: Downloader) {
        lock.lock()
        live[ObjectIdentifier(downloader)] = downloader
        lock.unlock()
    }

    /// Moves a finished lane's bytes from in-flight to settled in one step, so the total
    /// never dips.
    func left(_ downloader: Downloader, carrying bytes: Int64) {
        lock.lock()
        live[ObjectIdentifier(downloader)] = nil
        settled += bytes
        lock.unlock()
    }

    var received: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return settled + live.values.reduce(0) { $0 + $1.progress.received }
    }

    /// Bytes of the finished lanes only, so an average tile size is never taken over
    /// part-arrived tiles.
    var finished: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }
}
