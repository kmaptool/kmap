import Foundation

/// Sorts and deduplicates collected OSM ids across every core.
enum IDSort {
    /// Below this a run is sorted in place: threads cost more than the sort saves.
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
                    target.advanced(by: at).update(from: from,
                                                   count: source.count)
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
        guard total > leastWorthSplitting else {
            ids.sort()
            return
        }
        let lanes = max(2, min(Machine.fastCores, total / leastPerLane))
        var step = (total + lanes - 1) / lanes
        ids.withUnsafeMutableBufferPointer { source in
            DispatchQueue.concurrentPerform(iterations: (total + step - 1) / step) { lane in
                let low = lane * step, high = min(total, low + step)
                guard low < high else { return }
                var chunk = UnsafeMutableBufferPointer(rebasing: source[low..<high])
                chunk.sort()
            }
        }

        var scratch = [Int64](repeating: 0, count: total)
        var settled = true                      // whether the ordered data is in `ids`
        while step < total {
            let pairs = (total + 2 * step - 1) / (2 * step)
            let width = step
            ids.withUnsafeMutableBufferPointer { a in
                scratch.withUnsafeMutableBufferPointer { b in
                    let from = settled ? a : b
                    let into = settled ? b : a
                    DispatchQueue.concurrentPerform(iterations: pairs) { pair in
                        let low = pair * 2 * width
                        let middle = min(total, low + width)
                        let high = min(total, low + 2 * width)
                        merge(from, low: low, middle: middle, high: high, into: into)
                    }
                }
            }
            settled.toggle()
            step *= 2
        }
        if !settled { ids = scratch }
    }

    /// Merges two neighbouring sorted runs into `into`.
    private static func merge(_ from: UnsafeMutableBufferPointer<Int64>,
                              low: Int, middle: Int, high: Int,
                              into: UnsafeMutableBufferPointer<Int64>) {
        guard low < high else { return }
        var left = low, right = middle, at = low
        while left < middle && right < high {
            if from[left] <= from[right] {
                into[at] = from[left]; left += 1
            } else {
                into[at] = from[right]; right += 1
            }
            at += 1
        }
        while left < middle { into[at] = from[left]; left += 1; at += 1 }
        while right < high { into[at] = from[right]; right += 1; at += 1 }
    }
}
