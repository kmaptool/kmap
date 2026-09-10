import Foundation

/// Witnesses from the zoomed-out levels, for what never reaches the detailed one.
///
/// A style may draw a whole vocabulary only when zoomed out — a reserve's hatch over
/// half a district, a thin stroke standing in for a motorway. Up close there is no such
/// element at all, and the recovery would read the code as never used. The coarse
/// drawing cannot be matched vertex-for-vertex: it is simplified and its lattice is
/// coarse. So a coarse shape or line is identified by vertex containment instead — its corners quantized onto a ~76 m lattice and looked up among
/// the ground's ways on the same lattice. A member way inherits its relation's tags in
/// the ground index, which is how a ring assembled from dozens of boundary pieces still
/// answers with the reserve's own meaning. Candidates that disagree about the meaning
/// leave the element unidentified: containment is looser than alignment, and two
/// meanings standing is no meaning at all.
enum CoarseEvidence {

    /// Lattice coarseness: map units shifted right by this. Five bits is about 76 m —
    /// finer than the drawing it measures, coarser than the simplification noise.
    static let latticeShift: UInt64 = 5

    /// A cell more ways pass through than this says nothing about any of them.
    static let tooBusyCell = 32

    /// The least element corners a candidate must hold to qualify, and the fraction
    /// of them it must hold on a large element.
    static let fewestShared = 6
    static let cornerShare = 3

    static func quantize(_ cell: UInt64, shift: UInt64 = latticeShift) -> UInt64 {
        (((cell >> 32) >> shift) << 32) | ((cell & 0xFFFF_FFFF) >> shift)
    }

    /// One extract's ways, indexed by a lattice of the given coarseness.
    struct Lattice {
        let shift: UInt64
        var wayCells: [[UInt64]] = []
        var byCell: [UInt64: [Int32]] = [:]
        /// Which of the ways are closed rings. A point standing on a road is not the
        /// road; a point inside a building may well be the building, which is how
        /// mkgmap plants a point for a tagged area in the first place.
        var closed: [Bool] = []

        init(_ index: GroundIndex, shift: UInt64 = CoarseEvidence.latticeShift,
             ringsOnly: Bool = false) {
            self.shift = shift
            wayCells.reserveCapacity(index.ways.count)
            closed.reserveCapacity(index.ways.count)
            for (slot, way) in index.ways.enumerated() {
                var seen = Set<UInt64>()
                var cells: [UInt64] = []
                for cell in way.cells {
                    let q = quantize(cell, shift: shift)
                    if seen.insert(q).inserted { cells.append(q) }
                }
                let ring = way.cells.count >= GarminGrid.ringVertices
                    && way.cells.first == way.cells.last
                closed.append(ring)
                wayCells.append(cells)
                guard !ringsOnly || ring else { continue }
                for q in cells { byCell[q, default: []].append(Int32(slot)) }
            }
            // A cell half the town passes through names nobody.
            byCell = byCell.filter { $0.value.count <= tooBusyCell }
        }
    }

    /// The tagged nodes of one extract on a zoomed-out level's lattice, for the points
    /// a style draws only there: a village that is a label at every zoom but the
    /// closest.
    struct PointLattice {
        let shift: Int
        var byCell: [UInt64: [Int32]] = [:]

        init(_ index: GroundIndex, shift: Int) {
            self.shift = shift
            for (slot, node) in index.nodes.enumerated() {
                byCell[GarminGrid.onLattice(node.cell, shift: shift), default: []]
                    .append(Int32(slot))
            }
        }
    }

    /// Reads every coarse-level element against one extract, adding witnesses for
    /// what qualifies. Elements the detailed pass already answers for are left alone:
    /// the evidence dedupes witnesses by source, so a second sighting costs nothing.
    static func match(_ dump: ElementDumper.Dump, index: GroundIndex,
                      into evidence: inout Evidence) {
        guard !dump.elements.isEmpty else { return }
        let lattice = Lattice(index)
        var points: [Int: PointLattice] = [:]
        for at in 0..<dump.count {
            let element = dump.elements[at]
            if element.kind == .point {
                // A point sits on its level's lattice; the nodes standing in that
                // cell name it when they all mean one thing.
                guard let resolution = dump.resolution(at),
                      let cell = dump.chain(at).first else { continue }
                let shift = GarminGrid.fullResolution - resolution
                if points[shift] == nil { points[shift] = PointLattice(index, shift: shift) }
                guard let slots = points[shift]?.byCell[cell], !slots.isEmpty else { continue }
                var meaning: String?
                var winner: Int32 = -1
                for slot in slots {
                    guard let tag = DefaultRuleBook.meaning(of: index.nodes[Int(slot)].tags)
                    else { continue }
                    if meaning == nil { meaning = tag; winner = slot }
                    else if meaning != tag { winner = -1; break }
                }
                guard winner >= 0 else { continue }
                let node = index.nodes[Int(winner)]
                evidence.witness(kind: .point, type: element.type, way: node.id,
                                 tags: node.tags, resolution: resolution)
                continue
            }
            var seen = Set<UInt64>()
            var corners: [UInt64] = []
            for cell in dump.chain(at) {
                let q = quantize(cell)
                if seen.insert(q).inserted { corners.append(q) }
            }
            guard corners.count >= fewestShared else { continue }

            var held: [Int32: Int] = [:]
            for corner in corners {
                for slot in lattice.byCell[corner] ?? [] { held[slot, default: 0] += 1 }
            }
            let wanted = max(fewestShared, corners.count / cornerShare)
            // A shape and a line are answered differently. A fill covers ground, so
            // everything under it must agree or it names nothing. A zoomed-out line
            // runs the length of one way and brushes past dozens — every road it
            // crosses, every river it follows — so unanimity would name nothing at
            // all; instead the way it shares most of its length with wins, and only
            // by a clear margin over the next meaning.
            var winner: Int32 = -1
            if element.kind == .area {
                // Ordered, as the line branch is: which way of the several agreeing
                // ones is recorded decides an id in the ledger, and a dictionary's own
                // order is not the same from one run to the next.
                let ranked = held.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
                    .filter { $0.value >= wanted }
                // The holes are asked last: a fill cut through a lake traces the lake's
                // ring too, and the lake is not what the fill means.
                if let one = unanimous(ranked, in: index) {
                    winner = one
                } else if let one = unanimous(ranked.filter { !index.isInner($0.key) },
                                              in: index) {
                    winner = one
                }
                guard winner >= 0 else { continue }
            } else {
                var best = (slot: Int32(-1), count: 0, tag: "")
                var runnerUp = 0
                for (slot, count) in held.sorted(by: { ($0.value, $0.key)
                                                       > ($1.value, $1.key) }) {
                    let tags = index.tags(ofWay: slot)
                    guard let tag = DefaultRuleBook.meaning(of: tags) else { continue }
                    if best.slot < 0 {
                        best = (slot, count, tag)
                    } else if tag != best.tag {
                        runnerUp = count
                        break
                    }
                }
                guard best.slot >= 0, best.count >= wanted,
                      best.count >= runnerUp * 2 else { continue }
                winner = best.slot
            }
            evidence.witness(kind: element.kind, type: element.type,
                             way: index.ways[Int(winner)].id,
                             tags: index.tags(ofWay: winner),
                             resolution: dump.resolution(at))
        }
    }

    /// The first of the candidates when all of them mean one thing, else nil.
    private static func unanimous(_ ranked: [(key: Int32, value: Int)],
                                  in index: GroundIndex) -> Int32? {
        var meaning: String?
        var winner: Int32 = -1
        for (slot, _) in ranked {
            guard let tag = DefaultRuleBook.meaning(of: index.tags(ofWay: slot)) else { continue }
            if meaning == nil {
                meaning = tag
                winner = slot
            } else if meaning != tag {
                return nil
            }
        }
        return winner >= 0 ? winner : nil
    }

    /// The rescue lattice for points: about 38 m, one step finer than the polygon one.
    static let rescueShift: UInt64 = 4

    /// Second chance for unmatched points: the same spot is looked up in the extract.
    /// mkgmap plants a point for a tagged area at the area's own label spot, so a shop
    /// drawn from its building has no node to fall on — the building does. The answer
    /// can be ambiguous, so it is taken only when everything standing there says one
    /// thing: the point's cell and its eight neighbours are gathered, and two distinct
    /// meanings among them identify nothing.
    static func rescuePoints(_ dump: ElementDumper.Dump,
                             matches: UnsafeMutableBufferPointer<UInt8>,
                             index: GroundIndex,
                             into evidence: inout Evidence,
                             progress: RecoverProgress? = nil) async {
        // Gathered first, then looked up over every core: the lattice is built once
        // and only read, and each core writes its own span of the match table.
        var wanted: [Int] = []
        for at in 0..<dump.count
        where dump.elements[at].kind == .point
            && matches[at] == Evidence.Match.unmatched.rawValue {
            wanted.append(at)
        }
        guard !wanted.isEmpty else { return }
        progress?.count(0, of: wanted.count)
        // Rings only: a bus stop beside a road would otherwise be identified as the
        // road it stands on, and the whole style would learn that roads are bus stops.
        let lattice = Lattice(index, shift: rescueShift, ringsOnly: true)

        let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount,
                               StyleRecovery.mostCores))
        let span = (wanted.count + cores - 1) / cores
        let all = wanted
        await withTaskGroup(of: (Evidence, [Int]).self) { group in
            for core in 0..<cores {
                let from = core * span
                let upTo = min(all.count, from + span)
                guard from < upTo else { continue }
                group.addTask {
                    var mine = Evidence()
                    var rescued: [Int] = []
                    var stepped = 0
                    for at in all[from..<upTo] {
                        stepped += 1
                        if stepped % StyleRecovery.progressStride == 0 {
                            progress?.advance(StyleRecovery.progressStride)
                        }
                        let element = dump.elements[at]
                        guard let cell = dump.chain(at).first,
                              let (slot, tags) = place(of: cell, lattice: lattice,
                                                       index: index) else { continue }
                        mine.witness(kind: element.kind, type: element.type,
                                     way: index.ways[Int(slot)].id, tags: tags)
                        rescued.append(at)
                    }
                    return (mine, rescued)
                }
            }
            for await (part, rescued) in group {
                evidence.merge(part)
                for at in rescued { matches[at] = Evidence.Match.matched.rawValue }
            }
        }
    }

    /// What stands at one spot, when everything standing there says one thing.
    private static func place(of cell: UInt64, lattice: Lattice, index: GroundIndex)
        -> (slot: Int32, tags: [String: String])? {
        let q = quantize(cell, shift: rescueShift)
        let lat = q >> 32, lon = q & 0xFFFF_FFFF
        var meaning: String?
        var winner: Int32 = -1
        for dy in -1...1 {
            for dx in -1...1 {
                let neighbour = (UInt64(bitPattern: Int64(lat) &+ Int64(dy)) << 32)
                    | (UInt64(bitPattern: Int64(lon) &+ Int64(dx)) & 0xFFFF_FFFF)
                for slot in lattice.byCell[neighbour] ?? [] {
                    let tags = index.tags(ofWay: slot)
                    guard let tag = DefaultRuleBook.meaning(of: tags) else { continue }
                    if meaning == nil {
                        meaning = tag
                        winner = slot
                    } else if meaning != tag {
                        return nil
                    }
                }
            }
        }
        guard winner >= 0 else { return nil }
        return (winner, index.tags(ofWay: winner))
    }
}
