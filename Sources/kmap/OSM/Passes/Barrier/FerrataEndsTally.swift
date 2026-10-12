import Foundation

/// The ends of each via ferrata route across an extract: a node ending 1 via ferrata way,
/// not the joint between 2 pieces of a route, nor a branch meeting a route midway.
struct FerrataEndsTally {
    private var counts: [Int64: Int] = [:]
    private var inner: Set<Int64> = []

    mutating func add(_ block: FerrataEnds) {
        for node in block.nodes { counts[node, default: 0] += 1 }
        inner.formUnion(block.inner)
    }

    var routeEnds: Set<Int64> {
        Set(counts.compactMap { $0.value == 1 && !inner.contains($0.key) ? $0.key : nil })
    }
}
