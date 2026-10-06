import Foundation

/// Witnesses from the zoomed-out levels, for what never reaches the detailed one.
///
/// A style may draw something only zoomed out: a reserve's hatch over half a district, a
/// thin stroke standing in for a motorway. Up close there is no such element, and the code
/// would read as never used. The coarse drawing is simplified and cannot be matched vertex
/// for vertex, so its corners are quantized onto a ~76 m lattice and looked up among the
/// ground's ways on the same lattice. A member way inherits its relation's tags, so a ring
/// built from dozens of boundary pieces still answers with the reserve's meaning.
/// Candidates that disagree leave the element unidentified: containment is looser than
/// alignment, and 2 meanings standing is none.
enum CoarseEvidence {
    /// Lattice coarseness: map units shifted right by this. 5 bits is about 76 m: finer than
    /// the drawing it measures, coarser than the simplification noise.
    static let latticeShift: UInt64 = 5

    /// A cell more ways pass through than this says nothing about any of them.
    static let tooBusyCell = 32

    /// The least element corners a candidate must hold to qualify, and the fraction
    /// of them it must hold on a large element.
    static let fewestShared = 6
    static let cornerShare = 3

    /// Each half shifted as the signed number it is, so the cells either side of the
    /// equator and of Greenwich stay neighbours: -1 and 0 shift to -1 and 0.
    static func quantize(_ cell: UInt64, shift: UInt64 = latticeShift) -> UInt64 {
        let lat = Int32(bitPattern: UInt32(truncatingIfNeeded: cell >> 32)) >> Int32(shift)
        let lon = Int32(bitPattern: UInt32(truncatingIfNeeded: cell)) >> Int32(shift)
        return UInt64(UInt32(bitPattern: lat)) << 32 | UInt64(UInt32(bitPattern: lon))
    }

    /// Reads every coarse-level element against one extract, adding witnesses for
    /// what qualifies.
    static func match(
        _ dump: ElementDumper.Dump,
        index: GroundIndex,
        into evidence: inout Evidence
    ) {
        var answered = [Bool](repeating: false, count: dump.count)
        match(dump, index: index, answered: &answered, into: &evidence)
    }

    /// As above, over several extracts in turn: `answered` marks the elements an
    /// earlier extract already witnessed, which an overlapping one would count again.
    static func match(
        _ dump: ElementDumper.Dump,
        index: GroundIndex,
        answered: inout [Bool],
        into evidence: inout Evidence
    ) {
        guard !dump.elements.isEmpty else { return }
        let lattice = Lattice(index)
        var points: [Int: PointLattice] = [:]
        for at in 0..<dump.count where !answered[at] {
            // Left part-done: the caller checks the cancellation and throws.
            if at % StyleRecovery.progressStride == 0, Task.isCancelled { return }
            let element = dump.elements[at]
            if element.kind == .point {
                // A point sits on its level's lattice; the nodes standing in that
                // cell name it when they all mean one thing.
                guard let resolution = dump.resolution(at),
                    let cell = dump.chain(at).first
                else { continue }
                let shift = GarminGrid.fullResolution - resolution
                if points[shift] == nil { points[shift] = PointLattice(index, shift: shift) }
                guard let slots = points[shift]?.byCell[cell], !slots.isEmpty else { continue }
                var meaning: String?
                var winner: Int32 = -1
                for slot in slots {
                    guard let tag = DefaultRuleBook.meaning(of: index.nodes[Int(slot)].tags)
                    else { continue }
                    if meaning == nil { meaning = tag; winner = slot } else if meaning != tag { winner = -1; break }
                }
                guard winner >= 0 else { continue }
                let node = index.nodes[Int(winner)]
                evidence.witness(
                    kind: .point,
                    type: element.type,
                    way: node.id,
                    tags: node.tags,
                    resolution: resolution
                )
                answered[at] = true
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
            // runs the length of one way and brushes past dozens - every road it
            // crosses, every river it follows - so unanimity would name nothing at
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
                } else if let one = unanimous(
                    ranked.filter { !index.isInner($0.key) },
                    in: index
                ) {
                    winner = one
                }
                guard winner >= 0 else { continue }
            } else {
                var best = (slot: Int32(-1), count: 0, tag: "")
                var runnerUp = 0
                for (slot, count) in held.sorted(by: {
                    ($0.value, $0.key)
                        > ($1.value, $1.key)
                }) {
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
                    best.count >= runnerUp * 2
                else { continue }
                winner = best.slot
            }
            evidence.witness(
                kind: element.kind,
                type: element.type,
                way: index.ways[Int(winner)].id,
                tags: index.tags(ofWay: winner),
                resolution: dump.resolution(at)
            )
            answered[at] = true
        }
    }

    /// The first of the candidates when all of them mean one thing, else nil.
    private static func unanimous(
        _ ranked: [(key: Int32, value: Int)],
        in index: GroundIndex
    ) -> Int32? {
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

    /// Second chance for unmatched points: the same spot is looked up in the extract. mkgmap
    /// plants a point for a tagged area at the area's label spot, so a shop drawn from its
    /// building has no node to fall on; the building does. Taken only when everything there
    /// says one thing: the point's cell and its 8 neighbours are gathered, and 2 distinct
    /// meanings among them identify nothing.
    ///
    /// Returned, not recorded: a later extract's exact match goes first; see `settle`.
    static func rescuePoints(
        _ dump: ElementDumper.Dump,
        matches: UnsafeMutableBufferPointer<UInt8>,
        index: GroundIndex,
        skipping rescued: Set<Int> = [],
        progress: RecoverProgress? = nil
    ) async -> [Rescue] {
        // Gathered first, then looked up over every core: the lattice is built once
        // and only read, and each core keeps the rescues of its own span.
        var wanted: [Int] = []
        for at in 0..<dump.count
        where dump.elements[at].kind == .point
            && matches[at] == Evidence.Match.unmatched.rawValue && !rescued.contains(at)
        {
            wanted.append(at)
        }
        guard !wanted.isEmpty else { return [] }
        progress?.count(0, of: wanted.count)
        // Rings only: a bus stop beside a road would otherwise be identified as the
        // road it stands on, and the whole style would learn that roads are bus stops.
        let lattice = Lattice(index, shift: rescueShift, ringsOnly: true)

        let cores = max(
            1,
            min(
                ProcessInfo.processInfo.activeProcessorCount,
                StyleRecovery.mostCores
            )
        )
        let span = (wanted.count + cores - 1) / cores
        let all = wanted
        // Each core's part goes to its own place, not back through the group: see
        // `ExtractLocator.newestAnswering`. Merged in core order once all are done.
        let parts = Locked([[Rescue]?](repeating: nil, count: cores))
        await withTaskGroup(of: Void.self) { group in
            for core in 0..<cores {
                let from = core * span
                let upTo = min(all.count, from + span)
                guard from < upTo else { continue }
                group.addTask {
                    var rescued: [Rescue] = []
                    var stepped = 0
                    for at in all[from..<upTo] {
                        stepped += 1
                        if stepped % StyleRecovery.progressStride == 0 {
                            if Task.isCancelled { break }
                            progress?.advance(StyleRecovery.progressStride)
                        }
                        let element = dump.elements[at]
                        guard let cell = dump.chain(at).first,
                            let (slot, tags) = place(
                                of: cell,
                                lattice: lattice,
                                index: index
                            )
                        else { continue }
                        rescued.append(
                            Rescue(
                                at: at,
                                kind: element.kind,
                                type: element.type,
                                way: index.ways[Int(slot)].id,
                                tags: tags
                            )
                        )
                    }
                    let part = rescued
                    parts.withLock { $0[core] = part }
                }
            }
        }
        // In core order, which is the points' own order.
        return parts.withLock { $0 }.compactMap { $0 }.flatMap { $0 }
    }

    /// Records rescues of points still unmatched, the first extract's where several gave one.
    static func settle(
        _ rescues: [Rescue],
        matches: UnsafeMutableBufferPointer<UInt8>,
        into evidence: inout Evidence
    ) {
        for rescue in rescues where matches[rescue.at] == Evidence.Match.unmatched.rawValue {
            evidence.witness(kind: rescue.kind, type: rescue.type, way: rescue.way, tags: rescue.tags)
            matches[rescue.at] = Evidence.Match.matched.rawValue
        }
    }

    /// What stands at one spot, when everything standing there says one thing.
    private static func place(
        of cell: UInt64,
        lattice: Lattice,
        index: GroundIndex
    ) -> (slot: Int32, tags: [String: String])? {
        let q = quantize(cell, shift: rescueShift)
        let lat = Int32(bitPattern: UInt32(truncatingIfNeeded: q >> 32))
        let lon = Int32(bitPattern: UInt32(truncatingIfNeeded: q))
        var meaning: String?
        var winner: Int32 = -1
        for dy in -1...1 {
            for dx in -1...1 {
                let neighbour =
                    UInt64(UInt32(bitPattern: lat &+ Int32(dy))) << 32
                    | UInt64(UInt32(bitPattern: lon &+ Int32(dx)))
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
