import Foundation

/// What the write pass needs to know beyond which tile a point is in: which tiles each
/// spanning way and each relation must be written to, and which nodes go with them.
extension TileSplitter {
    func planProblems(assignment: Assignment, lookup: AreaLookup,
                              areas: [Area]) throws -> Plan {
        var mark = Date()
        func took(_ what: String) {
            if let line = Measured.line("  " + what, since: mark, atLeast: 0.05) { log(line) }
            mark = Date()
        }

        var plan = Plan()

        // The scaffolding is built inside a scope of its own so that this one holds no
        // reference to it afterwards. It is gigabytes of small allocations; `Unmanaged`
        // hands the last reference to a background queue, so the release that frees it
        // does not run here.
        let handoff: Unmanaged<ProblemScaffold> = try {
            let held = ProblemScaffold()

            try sweep(held, assignment: assignment)
            took("swept for spanning ways and relations")
            log("\(held.problemWays.count) way(s) span tiles, \(held.relations.count) relation(s) held,"
                + " \(held.sets.count - 1) distinct tile set(s) between them")

            // A spanning way is written whole to every tile it touches.
            plan.wayTiles = held.problemWays

            chooseCarried(held)
            took("chose the carried relations")

            try readRefs(held, plan: plan)
            took("read the way refs")

            try readRingCoordinates(held)
            took("read the ring coordinates")

            fillRings(held, areas: areas)
            took("filled the rings")

            carryMembers(held, plan: &plan)
            took("carried the members")

            spreadTilesOntoNodes(held, plan: &plan)
            took("spread the tiles onto the nodes")

            placeRelations(held, plan: &plan, assignment: assignment, areas: areas)
            took("placed the relations")
            return Unmanaged.passRetained(held)
        }()
        DispatchQueue.global(qos: .background).async { handoff.release() }
        took("handed the scaffolding over")
        return plan
    }

    /// Everything the problem pass builds on its way to a plan and the pipeline never
    /// keeps: the tile sets, the spanning ways, the relation records, the way refs and the
    /// ring coordinates.
    private final class ProblemScaffold {
        var sets = TileSets()
        var problemWays: [Int64: Int32] = [:]
        let wayArea = NodeAreas(expecting: 1 << 20)
        var relations: [Int64: RelationRecord] = [:]
        var carriedRelations: [Int64] = []
        var fillRelations: [Int64] = []
        var wanted: Set<Int64> = []
        var wantedWays = WantedIDs([])
        var refs = WayRefs(wanted: WantedIDs([]))
        var coordWanted: Set<Int64> = []
        var wantedNodes = WantedIDs([])
        var coords = NodeCoords(wanted: WantedIDs([]))
        var carriedTiles: [Int64: Set<UInt16>] = [:]
        var incomplete: [Int64: Bool] = [:]
        var spanning: [(key: Int64, value: Int32)] = []
    }

    /// First sweep over ways and relations: which areas does each touch.
    private func sweep(_ s: ProblemScaffold, assignment: Assignment) throws {
        for input in options.inputs {
            // Relations are gathered here and resolved in one batch below: a file's ways
            // all precede its relations, and the batch runs before the next file adds one.
            var pending: [(id: Int64, record: RelationRecord)] = []
            try PBFReader(url: input).readInOrder(make: {
                ProblemScan(nodes: assignment.nodes)
            }) { scan in
                for (id, tile, span) in scan.outWays {
                    if tile == ProblemScan.several {
                        s.problemWays[id] = s.sets.intern(scan.spans[Int(span)])
                        s.wayArea.set(id, NodeAreas.outside)
                    } else {
                        s.wayArea.set(id, tile)
                    }
                }
                pending.append(contentsOf: scan.rawRelations)
                scan.clear()
            }

            // Which tiles each relation reaches, on every core: the way table and the
            // spanning sets are read-only by now, and the chunks merge back in order.
            let workers = max(1, min(Machine.workers, pending.count))
            if !pending.isEmpty {
                let chunk = (pending.count + workers - 1) / workers
                var resolved = [[(Int64, RelationRecord)]](repeating: [], count: workers)
                let problemWays = s.problemWays
                let sets = s.sets
                let wayArea = s.wayArea
                resolved.withUnsafeMutableBufferPointer { slots in
                    DispatchQueue.concurrentPerform(iterations: workers) { w in
                        let lo = w * chunk, hi = min(pending.count, lo + chunk)
                        guard lo < hi else { return }
                        var out: [(Int64, RelationRecord)] = []
                        out.reserveCapacity(hi - lo)
                        for at in lo..<hi {
                            var record = pending[at].record
                            for ref in record.memberWays {
                                if let area = wayArea.get(ref) {
                                    if area != NodeAreas.outside {
                                        record.directTiles.insert(area)
                                    } else if let spanned = problemWays[ref] {
                                        record.directTiles.formUnion(sets[spanned])
                                    }
                                } else {
                                    record.hasMissingMember = true
                                }
                            }
                            out.append((pending[at].id, record))
                        }
                        slots[w] = out
                    }
                }
                for part in resolved {
                    for (id, record) in part { s.relations[id] = record }
                }
            }
        }
    }

    /// Chooses the carried relations: the four types mkgmap must see complete, where they
    /// touch more than one tile or are built out of member relations. Their members follow
    /// them everywhere they go.
    private func chooseCarried(_ s: ProblemScaffold) {
        for (id, record) in s.relations where record.carriesMembers {
            guard record.directTiles.count > 1 || !record.memberRelations.isEmpty else {
                continue
            }
            s.carriedRelations.append(id)
            if record.fillsRings { s.fillRelations.append(id) }
        }
    }

    /// Node lists for every way that is either spanning or carried: their nodes follow
    /// them into the extra tiles, and their geometry closes the multipolygons' rings.
    private func readRefs(_ s: ProblemScaffold, plan: Plan) throws {
        s.wanted = Set(plan.wayTiles.keys)
        for rel in s.carriedRelations {
            for way in s.relations[rel]?.memberWays ?? [] { s.wanted.insert(way) }
        }
        // Nothing here cares which order the ways arrive in, so every core reads.
        s.wantedWays = WantedIDs(s.wanted)
        s.refs = WayRefs(wanted: s.wantedWays)
        let wantedWays = s.wantedWays
        for input in options.inputs {
            try PBFReader(url: input).readInOrder(make: { WayRefs(wanted: wantedWays) }) {
                part in
                s.refs.refs.merge(part.refs) { first, _ in first }
                part.refs.removeAll(keepingCapacity: true)
            }
        }
        if Measured.reported {
            var total = 0, room = 0
            for list in s.refs.refs.values { total += list.count; room += list.capacity }
            log("    \(s.refs.refs.count) way(s) held, \(total) ref(s) in all,"
                + " room for \(room)")
        }
    }

    /// Coordinates for the ring nodes of the fill candidates.
    private func readRingCoordinates(_ s: ProblemScaffold) throws {
        for rel in s.fillRelations {
            for way in s.relations[rel]?.memberWays ?? [] {
                for node in s.refs.refs[way] ?? [] { s.coordWanted.insert(node) }
            }
        }
        s.wantedNodes = WantedIDs(s.coordWanted)
        s.coords = NodeCoords(wanted: s.wantedNodes)
        let wantedNodes = s.wantedNodes
        if !wantedNodes.isEmpty {
            for input in options.inputs {
                try PBFReader(url: input).readInOrder(
                    make: { NodeCoords(wanted: wantedNodes) }) { part in
                    s.coords.coords.merge(part.coords) { first, _ in first }
                    part.coords.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    /// Claims tiles for the fill relations: closed rings claim every tile they enclose,
    /// open ones fall back to their bounding box.
    private func fillRings(_ s: ProblemScaffold, areas: [Area]) {
        for rel in s.carriedRelations {
            s.carriedTiles[rel] = s.relations[rel]?.directTiles ?? []
        }
        for rel in s.fillRelations {
            guard let record = s.relations[rel] else { continue }
            let rings = RingBuilder.rings(of: record.memberWays, refs: s.refs.refs,
                                          coords: s.coords.coords)
            var claimed = s.carriedTiles[rel] ?? []
            for (index, area) in areas.enumerated() {
                let tile = UInt16(index)
                guard !claimed.contains(tile) else { continue }
                // Against the frame widened by the shape overlap: a multipolygon is a
                // shape, and a tile paints shapes a little past its own edge.
                if rings.claims(area.grown(by: options.shapeOverlap)) {
                    claimed.insert(tile)
                }
            }
            s.carriedTiles[rel] = claimed
        }
    }

    /// Carry: member ways and nodes of the carried relations follow them everywhere.
    private func carryMembers(_ s: ProblemScaffold, plan: inout Plan) {
        for rel in s.carriedRelations {
            guard let record = s.relations[rel],
                  let touched = s.carriedTiles[rel], !touched.isEmpty else { continue }
            for way in record.memberWays {
                let already = plan.wayTiles[way].map { Set(s.sets[$0]) } ?? []
                plan.wayTiles[way] = s.sets.intern(already.union(touched))
            }
            let touchedIndex = plan.extra.intern(touched)
            for node in record.memberNodes {
                plan.extra.note(node, set: touchedIndex)
            }
        }
    }

    /// Spreads every carried or spanning way's tiles onto its nodes: interned once per
    /// way, appended per node, settled by one sort. Each worker takes a contiguous run of
    /// ways into pairs and a pool of its own; the order between workers does not matter.
    private func spreadTilesOntoNodes(_ s: ProblemScaffold, plan: inout Plan) {
        s.spanning = Array(plan.wayTiles)
        let spanning = s.spanning
        let refs = s.refs.refs
        let sets = s.sets
        let laneCount = max(1, min(Machine.workers, spanning.count))
        if laneCount > 1 {
            var lanes = [(pool: [[UInt16]], pairs: [(id: Int64, set: Int32)])](
                repeating: ([], []), count: laneCount)
            let chunk = (spanning.count + laneCount - 1) / laneCount
            lanes.withUnsafeMutableBufferPointer { slots in
                DispatchQueue.concurrentPerform(iterations: laneCount) { w in
                    let lo = w * chunk, hi = min(spanning.count, lo + chunk)
                    guard lo < hi else { return }
                    var pool: [[UInt16]] = []
                    // Keyed by the set's number: an integer compared rather than a set of
                    // tiles hashed and walked.
                    var index: [Int32: Int32] = [:]
                    var pairs: [(id: Int64, set: Int32)] = []
                    for at in lo..<hi {
                        let (way, tiles) = spanning[at]
                        guard let nodes = refs[way], !nodes.isEmpty else { continue }
                        let set: Int32
                        if let known = index[tiles] {
                            set = known
                        } else {
                            set = Int32(pool.count)
                            pool.append(sets[tiles])
                            index[tiles] = set
                        }
                        for node in nodes { pairs.append((node, set)) }
                    }
                    // Sorted here, on the lane's own core: settle merges the lanes'
                    // stretches instead of sorting every pair on one thread.
                    pairs.sort { $0.id < $1.id }
                    slots[w] = (pool, pairs)
                }
            }
            plan.extra.reserve(pairs: lanes.reduce(0) { $0 + $1.pairs.count })
            for at in lanes.indices {
                plan.extra.absorb(pool: lanes[at].pool, pairs: lanes[at].pairs, sorted: true)
                // Each lane is released as it is folded in; together they hold every pair
                // a second time.
                lanes[at] = ([], [])
            }
        } else {
            for (way, tiles) in plan.wayTiles {
                guard let nodes = refs[way], !nodes.isEmpty else { continue }
                let index = plan.extra.intern(Set(sets[tiles]))
                for node in nodes { plan.extra.note(node, set: index) }
            }
        }
        plan.extra.settle()
    }

    /// Places every relation. A carried type takes its computed tiles, or every tile when
    /// it is incomplete; any other follows its member ways to wherever those were written.
    /// Member relations contribute nothing.
    private func placeRelations(_ s: ProblemScaffold, plan: inout Plan,
                                assignment: Assignment, areas: [Area]) {
        // Incompleteness spreads upward: a relation is incomplete when a direct member
        // is absent from the extract, or when a member relation is itself incomplete.
        func isIncomplete(_ id: Int64, _ visited: inout Set<Int64>) -> Bool {
            if let done = s.incomplete[id] { return done }
            guard let record = s.relations[id] else { return true }
            guard !visited.contains(id) else { return false }
            visited.insert(id)
            var answer = record.hasMissingMember
            if !answer {
                for child in record.memberRelations
                where isIncomplete(child, &visited) {
                    answer = true
                    break
                }
            }
            s.incomplete[id] = answer
            return answer
        }

        let everyTile = Set((0..<areas.count).map { UInt16($0) })
        for (id, record) in s.relations {
            // No direct member found at all: nothing anchors it anywhere.
            if record.directTiles.isEmpty { continue }
            var touched: Set<UInt16>
            if record.carriesMembers {
                touched = s.carriedTiles[id] ?? record.directTiles
                var visited: Set<Int64> = []
                if (record.directTiles.count > 1 || !record.memberRelations.isEmpty),
                   isIncomplete(id, &visited) {
                    touched = everyTile
                }
            } else {
                touched = []
                for way in record.memberWays {
                    if let extra = plan.wayTiles[way] {
                        touched.formUnion(s.sets[extra])
                    } else if let value = s.wayArea.get(way), value != NodeAreas.outside {
                        touched.insert(value)
                    }
                }
                for node in record.memberNodes {
                    if let value = assignment.nodes.get(node) {
                        touched.formUnion(assignment.nodes.areas(of: value))
                    }
                }
            }
            if !touched.isEmpty { plan.relationTiles[id] = s.sets.intern(touched) }
        }

        plan.sets = s.sets
        plan.sets.sealed()
    }

    // MARK: Multipolygon rings
}
