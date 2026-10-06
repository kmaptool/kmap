import Foundation

/// The node ids of the ways asked for: the outer ways of the multipolygons a `.gpi`
/// carries.
struct MemberWays: OSMSink {
    let wantedParts: OSMParts = .ways
    /// Sorted.
    let wanted: [Int64]
    var found: [Int64: [Int64]] = [:]

    mutating func way(
        id: Int64,
        refs: ArraySlice<Int64>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        var low = 0, high = wanted.count
        while low < high {
            let middle = (low + high) / 2
            if wanted[middle] < id { low = middle + 1 } else { high = middle }
        }
        guard low < wanted.count, wanted[low] == id else { return }
        found[id] = Array(refs)
    }
}
