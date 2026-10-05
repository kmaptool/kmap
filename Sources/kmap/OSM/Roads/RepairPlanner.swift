import Foundation

/// Deciding which of the candidate gaps are broken junctions, and what to do about each.
/// The gates run in a fixed order: what stands between the two ends, then whether the two
/// lines merely run alongside each other, then what the ground does, and only then whether
/// a route already gets through.
struct RepairPlanner {
    /// Degrees in pi radians, for an angle in degrees.
    private static let halfTurnDegrees = 180.0
    /// A gap this close counts as the two lines already touching.
    static let touching = 0.05
    /// How far to look for a way round before calling the two ends unreachable.
    static let search = 400.0
    /// A gap narrower than this is closed however far round the router would go: one
    /// coordinate unit at the finest zoom is 2.39 m of latitude and as little as 1.19 m
    /// of longitude, so the ends are indistinguishable on the device.
    static let slip = 1.0
    /// Steeper than this, on ground rough enough that the DEM shows it, is a face.
    private static let cliffDegrees = 50.0
    /// How far the ground may sink between the ends, and how far one may stand above the
    /// other, before the DEM is taken to be showing a chasm rather than a slope.
    static let dip = 6.0
    static let step = 8.0
    /// Above this, in metres, nothing is getting over it and no link is drawn.
    private static let tooHigh = 2.0
    /// Closer than this, in metres, the DEM has nothing to say about the gap.
    private static let groundMinimum = 2.0
    /// A way arriving under this angle, in degrees, and not at an end of the other line,
    /// may be running alongside it rather than meeting it.
    private static let shallowDegrees = 20.0
    private static let nearStart = 0.02, nearEnd = 0.98
    /// How far back along the way `stillBeside` looks, in metres, and the least it needs.
    private static let lookBack = 30.0
    private static let stubLength = 10.0
    /// Two nodes are invented per bridge: the one on the other line and its middle.
    private static let nodesPerBridge = 2

    /// What the pass decided about a gap. Verdicts are counted by name, and the counts are
    /// what the build log prints.
    enum Verdict {
        static let building = "building", fence = "fence"
        static let joined = "joined"
        static let alreadyJoined = "already joined nearby"
        static let sameNode = "already the same node"
        static let alongside = "running alongside"
        static let wouldPull = "would pull another line off course"

        static func stoppedBy(_ what: String) -> String { "stopped by \(what)" }
        static func tooHigh(_ what: String, _ metres: Double) -> String {
            "stopped by \(what) over \(Int(metres)) m high"
        }
        static func bridged(_ what: String) -> String { "bridged over \(what.isEmpty ? "an obstacle" : what)" }
    }

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
    private struct Gap {
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
        if let hit = blockage {
            bridge(gap, over: hit, &state)
            return Verdict.bridged(hit.word)
        }
        // 2 ends reaching for each other: give them 1 node instead of 2, so the join is a
        // plain shared node and neither line grows a vertex.
        if let partner = loosePartner(of: gap, loose: loose, state: state) {
            merge(gap, with: partner, &state)
            return Verdict.joined
        }
        return attach(gap, &state)
    }

    /// A new node on the other line, and a link from the end over the obstacle to it.
    private func bridge(_ gap: Gap, over hit: Blockage, _ state: inout Planning) {
        // Invented nodes are numbered from far above any OSM node id, and from this pass's
        // own slice of that space, so 2 regions' inventions cannot share an id.
        let node = inventedIDBase + Int64(state.plan.bridges.count) * Int64(Self.nodesPerBridge)
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
            if isEnd, loose[slot], state.plan.moves[candidateRef] == nil,
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

    /// Whether the way is still within `reach` metres of the other line thirty metres back
    /// from its end, which separates a pavement from a switchback arriving shallow.
    private func stillBeside(
        candidate: RoadRepair.Candidate,
        at: Int,
        kx: Double,
        reach: Double,
        segment: Int
    ) -> Bool {
        let way = Int(candidate.way)
        let lo = Int(network.start[way]), hi = Int(network.start[way + 1])
        var i = at
        let step = candidate.atEnd ? -1 : 1
        var travelled = 0.0
        var plat = network.lat[i], plon = network.lon[i]
        while i + step >= lo, i + step < hi, travelled < Self.lookBack {
            i += step
            let nlat = network.lat[i], nlon = network.lon[i]
            let dx = (nlon - plon) * kx, dy = (nlat - plat) * RoadRepair.metresPerDegree
            travelled += (dx * dx + dy * dy).squareRoot()
            plat = nlat; plon = nlon
        }
        // A stub too short to judge is refused.
        if travelled < Self.stubLength { return true }
        // Distance to the INFINITE line through the matched segment, not to the other
        // way's polyline: a way duplicating that line stays at distance zero however far
        // back one walks, whereas a switchback's tail is genuinely off it.
        let ax = (network.lon[segment] - plon) * kx
        let ay = (network.lat[segment] - plat) * RoadRepair.metresPerDegree
        let bx = (network.lon[segment + 1] - plon) * kx
        let by = (network.lat[segment + 1] - plat) * RoadRepair.metresPerDegree
        let dx = bx - ax, dy = by - ay
        let length = (dx * dx + dy * dy).squareRoot()
        if length == 0 { return true }
        return abs(ax * dy - ay * dx) / length <= reach
    }

    private enum Gate {
        case refused(String)
        case allowed(Blockage?)
    }

    /// Everything that can stop a repair before the routing test is reached.
    private func stopped(_ gap: Gap, obstacles: CellTable) -> Gate {
        let p = gap.origin, q = gap.landing
        var blocked = blockedBy(p.lat, p.lon, q.lat, q.lon, grid: obstacles, cell: RoadRepair.cellDegrees)
        if let refusal = refusal(by: blocked) { return .refused(refusal) }
        // A pavement running alongside a road is not a junction, however close it comes.
        if runsAlongside(gap) { return .refused(Verdict.alongside) }
        if let reason = groundSays(p.lat, p.lon, q.lat, q.lon, distance: gap.distance) {
            if !bridging { return .refused(Verdict.stoppedBy(reason.rawValue)) }
            if blocked == nil {
                blocked = Blockage(kind: reason == .ravine ? .ravine : .cliff, word: reason.rawValue, height: .nan)
            }
        }
        return .allowed(blocked)
    }

    /// Why an obstacle in the way refuses the repair outright, if it does.
    private func refusal(by blocked: Blockage?) -> String? {
        guard let hit = blocked else { return nil }
        if hit.kind.isImpassable {
            return Verdict.stoppedBy(hit.kind == .building ? Verdict.building : Verdict.fence)
        }
        if !bridging { return Verdict.stoppedBy(hit.word) }
        if hit.height.isFinite, Double(hit.height) > Self.tooHigh { return Verdict.tooHigh(hit.word, Self.tooHigh) }
        return nil
    }

    /// Whether the way arrives shallow and stays beside the other line: a pavement, not
    /// a junction.
    private func runsAlongside(_ gap: Gap) -> Bool {
        let p = gap.origin, kx = gap.kx
        let neighbour = gap.candidate.atEnd ? gap.at - 1 : gap.at + 1
        let v1 = ((p.lon - network.lon[neighbour]) * kx, (p.lat - network.lat[neighbour]) * RoadRepair.metresPerDegree)
        let v2 = ((gap.b.lon - gap.a.lon) * kx, (gap.b.lat - gap.a.lat) * RoadRepair.metresPerDegree)
        let n1 = (v1.0 * v1.0 + v1.1 * v1.1).squareRoot()
        let n2 = (v2.0 * v2.0 + v2.1 * v2.1).squareRoot()
        guard n1 > 0 && n2 > 0 else { return false }
        let cosine = abs(v1.0 * v2.0 + v1.1 * v2.1) / (n1 * n2)
        let angle = acos(max(-1, min(1, cosine))) * Self.halfTurnDegrees / .pi
        // The arrival angle alone cannot tell a pavement from a switchback, both arriving
        // shallow, so a shallow angle counts as alongside only when the way is still beside
        // the other line 30 metres back.
        let along = gap.candidate.along
        guard angle < Self.shallowDegrees && along > Self.nearStart && along < Self.nearEnd else { return false }
        return stillBeside(
            candidate: gap.candidate,
            at: gap.at,
            kx: kx,
            reach: gap.distance + limit,
            segment: gap.segment
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

    /// The first thing standing between the two points, and how high it is if OSM says.
    private func blockedBy(
        _ plat: Double,
        _ plon: Double,
        _ qlat: Double,
        _ qlon: Double,
        grid: CellTable,
        cell: Double
    ) -> Blockage? {
        let here = RoadRepair.key(plat, plon, cell)
        let span = RoadRepair.span(limit, cell: cell, lat: plat)
        for dy in -span.dy...span.dy {
            for dx in -span.dx...span.dx {
                for entry in grid.run(RoadRepair.neighbour(of: here, dy: dy, dx: dx)) {
                    let a = Int(entry)
                    if Self.crosses(
                        (plat, plon),
                        (qlat, qlon),
                        (network.obstacleLat[a], network.obstacleLon[a]),
                        (network.obstacleLat[a + 1], network.obstacleLon[a + 1])
                    ) {
                        let obstacle = network.obstacleOwning(point: a)
                        return Blockage(
                            kind: ObstacleKind(rawValue: network.obstacleKind[obstacle]) ?? .barrier,
                            word: network.vocabulary[Int(network.obstacleWord[obstacle])],
                            height: network.obstacleHeight[obstacle]
                        )
                    }
                }
            }
        }
        return nil
    }

    /// What the ground says against joining; the word is what the verdict prints.
    private enum Ground: String { case drop, ravine, face }

    private func groundSays(
        _ plat: Double,
        _ plon: Double,
        _ qlat: Double,
        _ qlon: Double,
        distance: Double
    ) -> Ground? {
        guard let terrain, distance > Self.groundMinimum else { return nil }
        guard let here = terrain.elevation(plat, plon),
            let there = terrain.elevation(qlat, qlon)
        else { return nil }
        if abs(here - there) > Self.step { return .drop }
        if let middle = terrain.elevation((plat + qlat) / 2, (plon + qlon) / 2),
            min(here, there) - middle > Self.dip
        {
            return .ravine
        }
        if let steep = terrain.slope(plat, plon), steep > Self.cliffDegrees { return .face }
        return nil
    }

    /// Obstacles are filed only in the cells a candidate stands in: a region carries
    /// millions of fences, of which few are anywhere near a gap.
    private func obstacleGrid(near candidates: [RoadRepair.Candidate]) -> CellTable {
        // As far as a link may reach: past 1 cell, the line to its landing leaves the 3 by 3.
        let wanted = RoadRepair.cells(around: candidates, of: network, cell: RoadRepair.cellDegrees, reach: limit)
        // Lanes take runs of obstacles and are joined in order, so each cell lists its
        // segments as 1 walk over the obstacles would.
        let network = network
        let count = network.obstacleCount
        let perLane = Self.obstaclesPerLane
        let lanes = (count + perLane - 1) / perLane
        let found = Locked([(keys: [Int64], points: [Int32])](repeating: ([], []), count: lanes))
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            let part = Self.segments(of: lane * perLane..<min(count, (lane + 1) * perLane), in: network, within: wanted)
            found.withLock { $0[lane] = part }
        }
        let parts = found.withLock { $0 }
        return CellTable(keys: parts.flatMap(\.keys), values: parts.flatMap(\.points))
    }

    /// Every cell of `wanted` each segment of these obstacles passes through, with the
    /// segment's first point. The point index is the payload: it names the segment without
    /// a second lookup and without a cap on how many points 1 obstacle may have.
    private static func segments(
        of obstacles: Range<Int>,
        in network: RoadNetwork,
        within wanted: CellTable
    ) -> (keys: [Int64], points: [Int32]) {
        var keys: [Int64] = [], points: [Int32] = []
        for obstacle in obstacles {
            let range = network.obstaclePoints(of: obstacle)
            guard range.count >= RoadNetwork.leastPoints else { continue }
            for a in range.lowerBound..<(range.upperBound - 1) {
                RoadRepair.cells(
                    network.obstacleLat[a],
                    network.obstacleLon[a],
                    network.obstacleLat[a + 1],
                    network.obstacleLon[a + 1],
                    RoadRepair.cellDegrees
                ) { key in
                    if wanted.contains(key) {
                        keys.append(key)
                        points.append(Int32(a))
                    }
                }
            }
        }
        return (keys, points)
    }

    /// Obstacles handed to a core at a time.
    private static let obstaclesPerLane = 1 << 13

    /// How far off a line a point may be and still count as sitting on it: two centimetres,
    /// the grid the coordinates live on, a PBF storing them to 1e-7 of a degree.
    private static let grazing = 2e-7

    /// Whether the two segments properly cross. A point exactly on the line counts as on
    /// the near side, so a fence starting on a road node blocks nothing; the dead band
    /// keeps the sign of the cross product stable within the coordinate grid.
    static func crosses(
        _ p: (Double, Double),
        _ q: (Double, Double),
        _ a: (Double, Double),
        _ b: (Double, Double)
    ) -> Bool {
        func beyond(_ o: (Double, Double), _ u: (Double, Double), _ v: (Double, Double)) -> Bool {
            let cross = (u.1 - o.1) * (v.0 - o.0) - (u.0 - o.0) * (v.1 - o.1)
            let span = ((u.0 - o.0) * (u.0 - o.0) + (u.1 - o.1) * (u.1 - o.1)).squareRoot()
            return cross > grazing * span
        }
        return beyond(a, b, p) != beyond(a, b, q) && beyond(p, q, a) != beyond(p, q, b)
    }
}
