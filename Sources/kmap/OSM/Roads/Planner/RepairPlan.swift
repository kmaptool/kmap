import Foundation

/// What the repair decided to do to the file: 4 kinds of change and no others. A node
/// moves, a way takes a node into its list, one node stands in for another, and a link is
/// drawn where something was in the way, or a road lengthened where its end may not move.
/// Nothing here removes anything.
struct RepairPlan {
    /// Node id to where it now sits.
    var moves: [Int64: (lat: Double, lon: Double)] = [:]
    /// Way index to the nodes it must take in: each after the node that starts its segment,
    /// and where along it. By node id rather than position, the planning network having
    /// dropped points the extract lacks; the segment index is a hint for a closed way.
    /// An `along` of `before` puts the node in front of its anchor: a way lengthened at its
    /// start.
    var inserts: [Int32: [(after: Int64, segment: Int32, along: Double, node: Int64)]] = [:]
    static let before = -1.0
    /// Node id to the node that now stands for it.
    var merges: [Int64: Int64] = [:]
    var bridges: [Bridge] = []
    /// The nodes a lengthened road ends on, on the other line.
    var extensions: [(node: Int64, lat: Double, lon: Double)] = []
    var counts: [String: Int] = [:]
    /// One line per candidate, in order: what was decided and why. For comparison against
    /// the reference implementation.
    var trace: [String] = []

    struct Bridge {
        var node: Int64  // the invented node, on the other line
        var lat: Double
        var lon: Double
        var end: Int64  // the loose end it reaches back to
        var word: String
        var height: Float
        var length: Double
        var middle: (lat: Double, lon: Double)
        var way: Int32  // the way that takes `node` into its list
        var segment: Int32
        var along: Double
    }
}
