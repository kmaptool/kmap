import Foundation

/// Which kind of way each barrier node stands on, a fact the style language cannot reach
/// because a node does not know which way contains it. One pass suffices: a PBF puts its
/// nodes before its ways, so the barrier ids are known by the time the ways arrive. Blocks
/// are decoded on every core and matched up in file order, which that ordering requires.
struct BarrierScan: OSMSink {
    static let kinds: Set<String> = [
        "gate", "lift_gate", "swing_gate", "kissing_gate", "bollard",
        "block", "cycle_barrier", "stile", "bus_trap", "chain", "gate_lock",
    ]
    private static let pathLike: Set<String> = ["path", "footway", "track", "bridleway", "cycleway", "steps"]
    private static let minorLike: Set<String> = ["service", "residential", "living_street",
                                         "unclassified", "driveway"]
    /// Ways that enclose a plot rather than lead anywhere; a gate set into one of these is
    /// a private entrance, and most gates on no road at all stand on one.
    private static let enclosure: Set<String> = ["fence", "wall", "hedge", "retaining_wall",
                                         "city_wall", "guard_rail"]

    /// What a barrier stands on. Ordered by which wins where a node belongs to several
    /// ways: `fence` sits just above `none`, so any road or path the gate also stands on
    /// takes precedence.
    enum Kind: Int, Comparable {
        case none = 0, fence, major, minor, path

        var word: String {
            switch self {
            case .none: return "none"
            case .fence: return "fence"
            case .major: return "major"
            case .minor: return "minor"
            case .path: return "path"
            }
        }

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// One block's worth: the barrier nodes it holds, and its ways as a flat run of refs
    /// with the class each way belongs to.
    private(set) var foundBarriers: [Int64] = []
    private(set) var wayRefs: [Int64] = []
    private(set) var wayKinds: [(from: Int32, to: Int32, kind: Kind)] = []

    mutating func clear() {
        foundBarriers.removeAll(keepingCapacity: true)
        wayRefs.removeAll(keepingCapacity: true)
        wayKinds.removeAll(keepingCapacity: true)
    }

    mutating func node(id: Int64, lat: Double, lon: Double,
                       tags: ArraySlice<Int32>, block: OSMBlock) {
        var at = tags.startIndex
        while at + 1 < tags.endIndex {
            if block.text(Int(tags[at])) == "barrier",
               Self.kinds.contains(block.text(Int(tags[at + 1]))) {
                foundBarriers.append(id)
                return
            }
            at += 2
        }
    }

    mutating func way(id: Int64, refs: ArraySlice<Int64>,
                      keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {
        var highway: String?
        var barrier: String?
        for (i, key) in keys.enumerated() {
            guard i < values.count else { break }
            switch block.text(Int(key)) {
            case "highway": highway = block.text(Int(values[values.startIndex + i]))
            case "barrier": barrier = block.text(Int(values[values.startIndex + i]))
            default: break
            }
        }

        let kind: Kind
        if let highway {
            kind = Self.pathLike.contains(highway) ? .path
                 : Self.minorLike.contains(highway) ? .minor : .major
        } else if let barrier, Self.enclosure.contains(barrier) {
            kind = .fence
        } else {
            return
        }

        let from = Int32(wayRefs.count)
        wayRefs.append(contentsOf: refs)
        wayKinds.append((from, Int32(wayRefs.count), kind))
    }
}

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

extension BarrierScan {
    /// Reads a whole extract: barrier nodes, then which way each stands on.
    /// - Returns: every barrier node, those on no way at all included, with kind `none`.
    static func classify(_ url: URL) throws -> [Int64: String] {
        var index = BarrierIndex()
        var on: [Int64: Kind] = [:]

        try PBFReader(url: url).readInOrder(make: { BarrierScan() }) { block in
            index.add(barriers: block.foundBarriers)
            for (from, to, kind) in block.wayKinds {
                for at in Int(from)..<Int(to) {
                    let ref = block.wayRefs[at]
                    guard index.holds(ref) else { continue }
                    if kind > (on[ref] ?? .none) { on[ref] = kind }
                }
            }
            block.clear()
        }

        var out: [Int64: String] = [:]
        out.reserveCapacity(index.count)
        for id in index.all { out[id] = (on[id] ?? .none).word }
        return out
    }
}
