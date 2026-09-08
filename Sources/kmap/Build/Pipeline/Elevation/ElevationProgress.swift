import Foundation

/// Byte totals across every download lane, settled and in flight both.
///
/// Thread-safe: every accessor is taken under the lock.
final class Flight {
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

/// The elevation download's progress line.
extension BuildPipeline {
    /// What the elevation download shows while it runs: tiles done, bytes, rate and time
    /// left. The total size is not known in advance, so the estimate rests on the weight
    /// of the tiles already finished.
    static func fetchLine(done: Int, of total: Int, received: Int64,
                          elapsed: TimeInterval, secondsLeft: Double?) -> String {
        var text = "Copernicus \(done)/\(total) · \(Fmt.bytes(received))"
        // No rate for the first second: the first tiles are still opening their
        // connections and the figure would swing wildly.
        guard elapsed > Remaining.settlesAfter, received > 0 else { return text }
        text += "  ·  \(Fmt.rate(Double(received) / elapsed))"
        guard let secondsLeft else { return text }
        return text + "  ·  \(Fmt.duration(secondsLeft)) left"
    }
}
