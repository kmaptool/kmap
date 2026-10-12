import Foundation

/// The nodes of each via ferrata in 1 block, noted while the barrier scan reads its ways:
/// its first and last, and the ones between, where a branch joins it.
struct FerrataEnds {
    private(set) var nodes: [Int64] = []
    private(set) var inner: [Int64] = []

    mutating func note(highway: String?, refs: ArraySlice<Int64>) {
        guard highway == "via_ferrata", let first = refs.first, let last = refs.last else { return }
        nodes.append(first)
        nodes.append(last)
        if refs.count > 2 { inner.append(contentsOf: refs.dropFirst().dropLast()) }
    }

    mutating func clear() {
        nodes.removeAll(keepingCapacity: true)
        inner.removeAll(keepingCapacity: true)
    }
}
