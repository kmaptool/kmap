import CVector
import Foundation

/// Sorts and deduplicates collected OSM ids across every core.
enum IDSort {
    /// Below this the standard sort is as fast as setting the radix sort up.
    static let leastWorthRadix = 1 << 10
    /// Below this a run is sorted on 1 core: threads cost more than the sort saves.
    static let leastWorthSplitting = 1 << 16
    /// The smallest chunk worth handing to a core of its own.
    private static let leastPerLane = 1 << 15

    /// Returns the ids of every run, in order and once each.
    static func unique(of runs: [[Int64]]) -> [Int64] {
        let total = runs.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        var all = [Int64](repeating: 0, count: total)
        all.withUnsafeMutableBufferPointer { destination in
            guard let target = destination.baseAddress else { return }
            var at = 0
            for run in runs {
                run.withUnsafeBufferPointer { source in
                    guard let from = source.baseAddress, source.count > 0 else { return }
                    target.advanced(by: at).update(
                        from: from,
                        count: source.count
                    )
                }
                at += run.count
            }
        }
        sort(&all)

        // Deduplicated in place, without a second array of this size.
        var kept = 1
        all.withUnsafeMutableBufferPointer { ids in
            for read in 1..<total where ids[read] != ids[kept - 1] {
                ids[kept] = ids[read]
                kept += 1
            }
        }
        all.removeLast(total - kept)
        return all
    }

    /// Sorts in place: chunks on their own cores, then merged in pairs, each round
    /// halving the number of runs left.
    static func sort(_ ids: inout [Int64]) {
        let total = ids.count
        guard total > leastWorthRadix else {
            ids.sort()
            return
        }
        var scratch = [Int64](repeating: 0, count: total)
        guard total > leastWorthSplitting else {
            let inScratch = ids.withUnsafeMutableBufferPointer { ids in
                scratch.withUnsafeMutableBufferPointer { kmap_sort_i64_either(ids.baseAddress, $0.baseAddress, total) }
            }
            // Where the passes left them: taken over, not copied back.
            if inScratch != 0 { swap(&ids, &scratch) }
            return
        }
        let lanes = max(2, min(Machine.fastCores, total / leastPerLane))
        var step = (total + lanes - 1) / lanes
        // Whether the ordered data is in `ids`; the merge starts from wherever the chunks are.
        var settled = sortChunks(&ids, of: step, scratch: &scratch)
        while step < total {
            ids.withUnsafeMutableBufferPointer { a in
                scratch.withUnsafeMutableBufferPointer { b in
                    mergeRound(from: settled ? a : b, into: settled ? b : a, runs: step, lanes: lanes)
                }
            }
            settled.toggle()
            step *= 2
        }
        if !settled { ids = scratch }
    }

    /// Sorts each stretch of `size` on a core of its own, by radix, in the same stretch
    /// of `scratch`. A chunk ends in either array, by how many bytes its ids differ in:
    /// they are gathered where most of them ended, and the answer is whether that is
    /// `ids`.
    static func sortChunks(_ ids: inout [Int64], of size: Int, scratch: inout [Int64]) -> Bool {  // internal for tests
        let total = ids.count
        let chunks = (total + size - 1) / size
        var inScratch = [Bool](repeating: false, count: chunks)
        return ids.withUnsafeMutableBufferPointer { source in
            scratch.withUnsafeMutableBufferPointer { room in
                inScratch.withUnsafeMutableBufferPointer { ended in
                    // Each lane sorts its own stretch, which no type can say: nothing is shared.
                    nonisolated(unsafe) let source = source, room = room, ended = ended
                    DispatchQueue.concurrentPerform(iterations: chunks) { lane in
                        let low = lane * size, high = min(total, low + size)
                        guard low < high else { return }
                        ended[lane] =
                            kmap_sort_i64_either(source.baseAddress! + low, room.baseAddress! + low, high - low) != 0
                    }
                }
                let toScratch = inScratch.filter { $0 }.count * 2 > chunks
                // The others are brought over, each on a core of its own as they were sorted.
                let moving = (0..<chunks).filter { inScratch[$0] != toScratch }
                nonisolated(unsafe) let (from, into) = toScratch ? (source, room) : (room, source)
                DispatchQueue.concurrentPerform(iterations: moving.count) { at in
                    let low = moving[at] * size, high = min(total, low + size)
                    into.baseAddress!.advanced(by: low).update(from: from.baseAddress! + low, count: high - low)
                }
                return !toScratch
            }
        }
    }

    /// Merges each neighbouring pair of sorted runs of `width` from `from` into `into`.
    /// The last rounds have fewer pairs than cores: each pair is then cut into pieces that
    /// merge on their own, so every round keeps every core busy.
    private static func mergeRound(
        from: UnsafeMutableBufferPointer<Int64>,
        into: UnsafeMutableBufferPointer<Int64>,
        runs width: Int,
        lanes: Int
    ) {
        let total = from.count
        let pairs = (total + 2 * width - 1) / (2 * width)
        let pieces = max(1, (lanes + pairs - 1) / pairs)
        // Each piece merges its own stretch of `from` into the same of `into`.
        nonisolated(unsafe) let from = from, into = into
        DispatchQueue.concurrentPerform(iterations: pairs * pieces) { job in
            let pair = job / pieces, piece = job % pieces
            let low = pair * 2 * width
            let middle = min(total, low + width)
            let high = min(total, low + 2 * width)
            let length = high - low
            let first = piece * length / pieces, last = (piece + 1) * length / pieces
            let fromLeft = split(from, low: low, middle: middle, high: high, at: first)
            let toLeft = split(from, low: low, middle: middle, high: high, at: last)
            merge(
                from,
                left: low + fromLeft..<low + toLeft,
                right: middle + first - fromLeft..<middle + last - toLeft,
                into: into,
                at: low + first
            )
        }
    }

    /// How many of the first `count` merged values of `low..<middle` and `middle..<high`
    /// come from the left run, a tie going to the left as `merge` takes it.
    static func split(
        _ from: UnsafeMutableBufferPointer<Int64>,
        low: Int,
        middle: Int,
        high: Int,
        at count: Int
    ) -> Int {
        let leftCount = middle - low, rightCount = high - middle
        var least = max(0, count - rightCount), most = min(count, leftCount)
        // The fewest from the left such that no right value taken is above a left one left.
        while least < most {
            let left = (least + most) / 2
            let right = count - left
            if right > 0 && left < leftCount && from[middle + right - 1] >= from[low + left] {
                least = left + 1
            } else {
                most = left
            }
        }
        return least
    }

    /// Merges 2 sorted runs of `from` into `into`, starting at `at`.
    private static func merge(
        _ from: UnsafeMutableBufferPointer<Int64>,
        left: Range<Int>,
        right: Range<Int>,
        into: UnsafeMutableBufferPointer<Int64>,
        at start: Int
    ) {
        var l = left.lowerBound, r = right.lowerBound, at = start
        while l < left.upperBound && r < right.upperBound {
            if from[l] <= from[r] {
                into[at] = from[l]; l += 1
            } else {
                into[at] = from[r]; r += 1
            }
            at += 1
        }
        while l < left.upperBound { into[at] = from[l]; l += 1; at += 1 }
        while r < right.upperBound { into[at] = from[r]; r += 1; at += 1 }
    }
}
