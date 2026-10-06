import Foundation

/// Deciding which of the candidate gaps are broken junctions, and what to do about each.
/// The gates run in a fixed order: what stands between the two ends, then whether the two
/// lines merely run alongside each other, then what the ground does, and only then whether
/// a route already gets through.
struct RepairPlanner {
    /// Degrees in pi radians, for an angle in degrees.
    static let halfTurnDegrees = 180.0
    /// A gap this close counts as the two lines already touching.
    static let touching = 0.05
    /// How far to look for a way round before calling the two ends unreachable.
    static let search = 400.0
    /// A gap narrower than this is closed however far round the router would go: one
    /// coordinate unit at the finest zoom is 2.39 m of latitude and as little as 1.19 m
    /// of longitude, so the ends are indistinguishable on the device.
    static let slip = 1.0
    /// Steeper than this, on ground rough enough that the DEM shows it, is a face.
    static let cliffDegrees = 50.0
    /// How far the ground may sink between the ends, and how far one may stand above the
    /// other, before the DEM is taken to be showing a chasm rather than a slope.
    static let dip = 6.0
    static let step = 8.0
    /// Above this, in metres, nothing is getting over it and no link is drawn.
    static let tooHigh = 2.0
    /// Closer than this, in metres, the DEM has nothing to say about the gap.
    static let groundMinimum = 2.0
    /// A way arriving under this angle, in degrees, and not at an end of the other line,
    /// may be running alongside it rather than meeting it.
    static let shallowDegrees = 20.0
    static let nearStart = 0.02, nearEnd = 0.98
    /// How far back along the way `stillBeside` looks, in metres, and the least it needs.
    static let lookBack = 30.0
    static let stubLength = 10.0
    /// Two nodes are invented per bridge: the one on the other line and its middle.
    private static let nodesPerBridge = 2

    /// What was found between two ends, in the obstacle's own words.
    struct Blockage {
        var kind: ObstacleKind
        var word: String
        var height: Float
    }

    let network: RoadNetwork
    let terrain: Terrain?
    let bridging: Bool
    let limit: Double
    var inventedIDBase: Int64 = 1 << 40

    /// Works out what to do about every candidate, in the order they were found.
    func plan(_ candidates: [RoadRepair.Candidate], loose: [Bool]) -> RepairPlan {
        let obstacles = obstacleGrid(near: candidates)
        var state = Planning(graph: LocalGraph(network: network, around: candidates))
        for candidate in candidates {
            let verdict = decide(candidate, &state, obstacles: obstacles, loose: loose)
            note(&state.plan, verdict, candidate)
        }
        // Flatten any chain, so 1 substitution in the writer is enough.
        for (gone, first) in state.plan.merges {
            var stands = first
            while let next = state.plan.merges[stands] { stands = next }
            state.plan.merges[gone] = stands
        }
        return state.plan
    }

    /// What planning holds as it goes from candidate to candidate.
    private struct Planning {
        var plan = RepairPlan()
        var graph: LocalGraph
        /// Ends this plan has already put into another line, as an insert or a bridge end.
        /// Such a node holds 2 lines together and is no longer loose for a third.
        var placed = Set<Int64>()
    }

    /// A candidate's gap as the plan leaves it by the time it is reached.
    struct Gap {
        let candidate: RoadRepair.Candidate
        /// The end's point, and the segment of the other line it reaches for.
        let at: Int
        let segment: Int
        let otherRange: Range<Int>
        /// The end's node, under the id it was merged into if it was.
        let ref: Int64
        let ends: (Int64, Int64)
        /// Where the end was mapped, where it stands now, and where it lands on the segment.
        let origin: (lat: Double, lon: Double)
        let here: (lat: Double, lon: Double)
        let a: (lat: Double, lon: Double)
        let b: (lat: Double, lon: Double)
        let landing: (lat: Double, lon: Double)
        let kx: Double

        var distance: Double { candidate.distance }
        /// The segment's number within the other line.
        var offset: Int32 { Int32(segment - otherRange.lowerBound) }
    }

    /// The gap a candidate names, or nil when its end is already a node of that segment.
    private func gap(for candidate: RoadRepair.Candidate, in plan: RepairPlan) -> Gap? {
        let range = network.points(of: Int(candidate.way))
        let at = candidate.atEnd ? range.upperBound - 1 : range.lowerBound
        let segment = Int(candidate.segment)
        // An end merged into a neighbour earlier now carries that neighbour's id. It can
        // still be short of a third line, and that join is a separate repair.
        var ref = network.refs[at]
        while let stands = plan.merges[ref] { ref = stands }
        let ends = (network.refs[segment], network.refs[segment + 1])
        if ref == ends.0 || ref == ends.1 { return nil }
        if plan.inserts[candidate.otherWay]?.contains(where: { $0.node == ref }) == true { return nil }

        let origin = (lat: network.lat[at], lon: network.lon[at])
        let a = (lat: network.lat[segment], lon: network.lon[segment])
        let b = (lat: network.lat[segment + 1], lon: network.lon[segment + 1])
        return Gap(
            candidate: candidate,
            at: at,
            segment: segment,
            otherRange: network.points(of: Int(candidate.otherWay)),
            ref: ref,
            ends: ends,
            origin: origin,
            here: plan.moves[ref].map { ($0.lat, $0.lon) } ?? origin,
            a: a,
            b: b,
            landing: (a.lat + candidate.along * (b.lat - a.lat), a.lon + candidate.along * (b.lon - a.lon)),
            kx: RoadRepair.metresPerLonDegree(at: origin.lat)
        )
    }

    /// Decides 1 candidate, applies the decision to the plan, and names it.
    private func decide(
        _ candidate: RoadRepair.Candidate,
        _ state: inout Planning,
        obstacles: CellTable,
        loose: [Bool]
    ) -> String {
        guard let gap = gap(for: candidate, in: state.plan) else { return Verdict.sameNode }
        let blockage: Blockage?
        switch stopped(gap, obstacles: obstacles) {
        case .refused(let reason): return reason
        case .allowed(let found): blockage = found
        }
        // A route that already exists is left alone, however far round it goes: closing
        // such a gap would add a shortcut that is not there on the ground.
        if state.graph.detour(from: gap.ref, to: gap.ends, cap: Self.search) != nil, gap.distance > Self.slip {
            return Verdict.alreadyJoined
        }
        // An end on a kerb, a wall or a pier is that line's node too: moved past what the
        // device can show, it would drag the line along. The road is lengthened instead.
        if blockage == nil, gap.distance > Self.slip, state.plan.moves[gap.ref] == nil,
            let held = obstaclesThrough(
                gap.origin.lat,
                gap.origin.lon,
                grid: obstacles,
                cell: RoadRepair.cellDegrees
            ).first
        {
            extend(gap, &state)
            return Verdict.extended(held.word)
        }
        if let hit = blockage {
            bridge(gap, over: hit, &state)
            return Verdict.bridged(hit.word)
        }
        // 2 ends reaching for each other: give them 1 node instead of 2, so the join is a
        // plain shared node and neither line grows a vertex. Not where the other end is a
        // gate in a fence or a corner of a wall: that node is the obstacle's too, and the
        // end is put into the other line beside it instead.
        if let partner = loosePartner(of: gap, loose: loose, state: state),
            !isObstacleVertex(
                network.lat[partner.point],
                network.lon[partner.point],
                grid: obstacles,
                cell: RoadRepair.cellDegrees
            )
        {
            merge(gap, with: partner, &state)
            return Verdict.joined
        }
        return attach(gap, &state)
    }

    /// The next invented node's id: from this pass's own slice, far above any OSM node id, so
    /// 2 regions' inventions cannot share an id.
    private func invented(_ state: Planning) -> Int64 {
        inventedIDBase + Int64(state.plan.bridges.count + state.plan.extensions.count) * Int64(Self.nodesPerBridge)
    }

    /// A new node on the other line, and the end's own way lengthened to it: the end stays
    /// where it is, on the obstacle it shares.
    private func extend(_ gap: Gap, _ state: inout Planning) {
        // Landing on 1 of the other line's own nodes: that node is taken, not a second one
        // made in the same place.
        let along = gap.candidate.along
        let vertex = along <= 0 ? gap.segment : along >= 1 ? gap.segment + 1 : nil
        let node = vertex.map { network.refs[$0] } ?? invented(state)
        if vertex == nil { state.plan.extensions.append((node: node, lat: gap.landing.lat, lon: gap.landing.lon)) }
        let own = network.points(of: Int(gap.candidate.way))
        state.plan.inserts[gap.candidate.way, default: []].append(
            (
                after: gap.ref,
                segment: Int32(gap.candidate.atEnd ? own.count - 1 : 0),
                along: gap.candidate.atEnd ? 1 : RepairPlan.before,
                node: node
            )
        )
        if vertex == nil {
            insert(node, into: gap, at: gap.landing, along: along, &state)
        } else {
            state.placed.insert(gap.ref)
            link(&state.graph, gap.ref, gap.ends, gap.landing, gap.a, gap.b)
        }
    }

    /// A new node on the other line, and a link from the end over the obstacle to it.
    private func bridge(_ gap: Gap, over hit: Blockage, _ state: inout Planning) {
        let node = invented(state)
        state.plan.bridges.append(
            RepairPlan.Bridge(
                node: node,
                lat: gap.landing.lat,
                lon: gap.landing.lon,
                end: gap.ref,
                word: hit.word,
                height: hit.height,
                length: gap.distance,
                middle: ((gap.origin.lat + gap.landing.lat) / 2, (gap.origin.lon + gap.landing.lon) / 2),
                way: gap.candidate.otherWay,
                segment: gap.offset,
                along: gap.candidate.along
            )
        )
        insert(node, into: gap, at: gap.landing, along: gap.candidate.along, &state)
    }

    /// The end and the other line's own loose end become 1 node, halfway between.
    private func merge(_ gap: Gap, with partner: (point: Int, ref: Int64), _ state: inout Planning) {
        // A node already put in place holds 2 lines together; moving it again would drag
        // one of them off its course.
        if gap.distance > Self.touching && state.plan.moves[gap.ref] == nil {
            state.plan.moves[gap.ref] = (
                (gap.here.lat + network.lat[partner.point]) / 2,
                (gap.here.lon + network.lon[partner.point]) / 2
            )
        }
        state.plan.merges[partner.ref] = gap.ref
        state.graph.adopt(partner.ref, into: gap.ref)
    }

    /// The end itself put into the other line, moved onto it if it stops short.
    private func attach(_ gap: Gap, _ state: inout Planning) -> String {
        var landing = gap.landing
        var along = gap.candidate.along
        // A node an earlier repair has moved is no longer where this candidate found it;
        // handing it to a third line would drag that line over.
        if state.plan.moves[gap.ref] != nil {
            let here = gap.here
            let (away, t) = RoadRepair.project(here.lat, here.lon, gap.a.lat, gap.a.lon, gap.b.lat, gap.b.lon, gap.kx)
            if away > Self.touching { return Verdict.wouldPull }
            landing = here
            along = t
        } else if gap.distance > Self.touching {
            state.plan.moves[gap.ref] = landing
        }
        insert(gap.ref, into: gap, at: landing, along: along, &state)
        return Verdict.joined
    }

    /// Puts `node` into the other line at `landing` and tells the graph.
    private func insert(
        _ node: Int64,
        into gap: Gap,
        at landing: (lat: Double, lon: Double),
        along: Double,
        _ state: inout Planning
    ) {
        state.plan.inserts[gap.candidate.otherWay, default: []].append(
            (after: network.refs[gap.segment], segment: gap.offset, along: along, node: node)
        )
        state.placed.insert(gap.ref)
        link(&state.graph, gap.ref, gap.ends, landing, gap.a, gap.b)
    }

    /// The other line's own loose end, when the segment's near node is one: an end not
    /// yet moved or merged, within reach. Joining two such ends means one shared node
    /// rather than a new vertex on either line.
    private func loosePartner(of gap: Gap, loose: [Bool], state: Planning) -> (point: Int, ref: Int64)? {
        let other = Int(gap.candidate.otherWay)
        for point in [gap.segment, gap.segment + 1] {
            let isEnd = point == gap.otherRange.lowerBound || point == gap.otherRange.upperBound - 1
            let slot = other * RoadRepair.endsPerWay + (point == gap.otherRange.lowerBound ? 0 : 1)
            let candidateRef = network.refs[point]
            let dx = (network.lon[point] - gap.here.lon) * gap.kx
            let dy = (network.lat[point] - gap.here.lat) * RoadRepair.metresPerDegree
            // A gate or a dead end mapped as one shares its node with nothing.
            if isEnd, loose[slot], state.plan.moves[candidateRef] == nil,
                !network.gates.contains(candidateRef), !network.noExit.contains(candidateRef),
                state.plan.merges[candidateRef] == nil, !state.placed.contains(candidateRef),
                (dx * dx + dy * dy).squareRoot() <= limit
            {
                return (point, candidateRef)
            }
        }
        return nil
    }

    /// Counts a verdict and records it against the candidate that earned it.
    private func note(_ plan: inout RepairPlan, _ reason: String, _ candidate: RoadRepair.Candidate) {
        plan.counts[reason, default: 0] += 1
        plan.trace.append(
            String(
                format: "%ld %ld %.3f %@",
                network.wayID[Int(candidate.way)],
                network.wayID[Int(candidate.otherWay)],
                candidate.distance,
                reason
            )
        )
    }

    /// Tells the graph what was just done, so later candidates judge the map as this repair
    /// leaves it: without it, a row of ends reaching for one line each sees no route.
    private func link(
        _ graph: inout LocalGraph,
        _ node: Int64,
        _ ends: (Int64, Int64),
        _ q: (Double, Double),
        _ a: (Double, Double),
        _ b: (Double, Double)
    ) {
        let kq = RoadRepair.metresPerLonDegree(at: q.0)
        for (ref, point) in [(ends.0, a), (ends.1, b)] {
            let dx = (point.1 - q.1) * kq, dy = (point.0 - q.0) * RoadRepair.metresPerDegree
            graph.link(node, ref, (dx * dx + dy * dy).squareRoot())
        }
    }
}
