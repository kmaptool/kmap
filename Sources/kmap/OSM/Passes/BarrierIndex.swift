import Foundation

/// Gathers the blocks a `BarrierScan` produces into the answer. Every way names its nodes
/// and almost none are barriers, so a bitmap of one bit per hashed id rejects nearly all
/// of them in a couple of cycles; the set is asked only about those that get past it.
struct BarrierIndex {
    private var barriers: Set<Int64> = []
    private var maybe: [UInt64]
    private let mask: Int

    /// - Parameter bits: bitmap size, kept sparse enough to be worth asking. The default
    ///   is a quarter of a megabyte, which sits in cache.
    init(bits: Int = 1 << 21) {
        maybe = [UInt64](repeating: 0, count: bits / 64)
        mask = bits - 1
    }

    /// Fibonacci hashing: 2^64 divided by the golden ratio, as a signed constant. One
    /// multiply scatters the sequential OSM ids evenly across the bitmap.
    private static let fibonacciScramble: Int64 = -0x61c8_8646_80b5_83eb

    private func slot(_ id: Int64) -> (word: Int, bit: UInt64) {
        let at = Int(truncatingIfNeeded: id &* Self.fibonacciScramble) & mask
        return (at >> 6, UInt64(1) << UInt64(at & 63))
    }

    mutating func add(barriers ids: [Int64]) {
        for id in ids {
            barriers.insert(id)
            let (word, bit) = slot(id)
            maybe[word] |= bit
        }
    }

    var count: Int { barriers.count }
    var all: Set<Int64> { barriers }

    func holds(_ id: Int64) -> Bool {
        let (word, bit) = slot(id)
        guard maybe[word] & bit != 0 else { return false }
        return barriers.contains(id)
    }
}
