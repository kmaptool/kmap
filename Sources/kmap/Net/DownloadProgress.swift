import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a separate module outside Apple's platforms, where this module
// does not exist.
import FoundationNetworking
#endif

/// Live state of a running download. Every property is safe to read from any thread.
final class DownloadProgress {
    private let lock = NSLock()

    private var _total: Int64 = 0
    private var _received: Int64 = 0
    private var _perPart: [Int64] = []
    private var _partTotals: [Int64] = []
    private var _startedAt = Date()
    private var _resumedBytes: Int64 = 0
    private var _stage: String = "preparing"

    var total: Int64 { lock.withLock { _total } }
    var received: Int64 { lock.withLock { _received } }
    var stage: String { lock.withLock { _stage } }

    var fraction: Double {
        lock.withLock { _total > 0 ? Double(_received) / Double(_total) : 0 }
    }

    /// Bytes per second over this run, excluding what was already on disk.
    var rate: Double {
        lock.withLock {
            let elapsed = Date().timeIntervalSince(_startedAt)
            guard elapsed > 0.5 else { return 0 }
            return Double(_received - _resumedBytes) / elapsed
        }
    }

    /// Seconds still to come, or infinity while there is not enough to estimate from.
    var eta: Double {
        lock.withLock {
            Remaining.seconds(received: _received, total: _total,
                              elapsed: Date().timeIntervalSince(_startedAt),
                              alreadyOnDisk: _resumedBytes) ?? .infinity
        }
    }

    /// Per-connection completion fractions, 0...1.
    var partFractions: [Double] {
        lock.withLock {
            zip(_perPart, _partTotals).map { $1 > 0 ? Double($0) / Double($1) : 0 }
        }
    }

    func begin(total: Int64, partTotals: [Int64], alreadyOnDisk: Int64) {
        lock.withLock {
            _total = total
            _partTotals = partTotals
            _perPart = Array(repeating: 0, count: partTotals.count)
            _received = alreadyOnDisk
            _resumedBytes = alreadyOnDisk
            _startedAt = Date()
        }
    }

    func seedPart(_ index: Int, bytes: Int64) {
        lock.withLock {
            guard _perPart.indices.contains(index) else { return }
            _perPart[index] = bytes
        }
    }

    func advance(part index: Int, by n: Int64) {
        lock.withLock {
            guard _perPart.indices.contains(index) else { return }
            _perPart[index] += n
            _received += n
        }
    }

    func setStage(_ s: String) { lock.withLock { _stage = s } }
}

private extension NSLock {
    private func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
