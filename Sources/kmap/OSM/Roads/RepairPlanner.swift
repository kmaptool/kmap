import Foundation

/// Deciding which of the candidate gaps are broken junctions, and what to do about each.
/// The gates run in a fixed order: what stands between the two ends, then whether the two
/// lines merely run alongside each other, then what the ground does, and only then whether
/// a route already gets through.
struct RepairPlanner {
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

    /// What the pass decided about a gap. Verdicts are counted by name, and the counts are
    /// what the build log prints.
    enum Verdict {
        static let joined = "joined"
        static let alreadyJoined = "already joined nearby"
        static let sameNode = "already the same node"
        static let alongside = "running alongside"
        static let wouldPull = "would pull another line off course"

        static func stoppedBy(_ what: String) -> String { "stopped by \(what)" }
        static func tooHigh(_ what: String, _ metres: Double) -> String {
            "stopped by \(what) over \(Int(metres)) m high"
        }
        static func bridged(_ what: String) -> String { "bridged over \(what)" }
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
        let cell = 0.0005
        let obstacles = obstacleGrid(near: candidates, cell: cell)
        var graph = LocalGraph(network: network, around: candidates)
        var plan = RepairPlan()
        // Invented nodes are numbered from far above any OSM node id, and from this pass's
        // own slice of that space, so two regions' inventions cannot share an id.
        let made: Int64 = inventedIDBase

        for candidate in candidates {
            let way = Int(candidate.way)
            let told = plan.trace.count
            let range = network.points(of: way)
            let at = candidate.atEnd ? range.upperBound - 1 : range.lowerBound
            let other = Int(candidate.otherWay)
            let otherRange = network.points(of: other)
            let segment = Int(candidate.segment)

            // An end merged into a neighbour earlier now carries that neighbour's id. It
            // can still be short of a third line, and that join is a separate repair.
            var ref = network.refs[at]
            while let stands = plan.merges[ref] { ref = stands }

            let ends = (network.refs[segment], network.refs[segment + 1])
            if ref == ends.0 || ref == ends.1 {
                note(&plan, Verdict.sameNode, candidate, told)
                continue
            }
            if plan.inserts[candidate.otherWay]?.contains(where: { $0.node == ref }) == true {
                note(&plan, Verdict.sameNode, candidate, told)
                continue
            }

            var plat = network.lat[at], plon = network.lon[at]
            if let moved = plan.moves[ref] { plat = moved.lat; plon = moved.lon }
            let alat = network.lat[segment], alon = network.lon[segment]
            let blat = network.lat[segment + 1], blon = network.lon[segment + 1]
            var qlat = alat + candidate.along * (blat - alat)
            var qlon = alon + candidate.along * (blon - alon)
            var along = candidate.along
            let distance = candidate.distance
            let kx = RoadRepair.metresPerDegree * cos(network.lat[at] * .pi / 180)

            switch stopped(at: (network.lat[at], network.lon[at]), reaching: (qlat, qlon),
                           distance: distance, obstacles: obstacles, cell: cell,
                           candidate: candidate, at: at, segment: segment) {
            case .refused(let reason):
                note(&plan, reason, candidate, told)
                continue
            case .allowed(let blockage):
                // A route that already exists is left alone, however far round it goes:
                // closing such a gap would add a shortcut that is not there on the ground.
                if graph.detour(from: ref, to: ends, cap: Self.search) != nil,
                   distance > Self.slip {
                    note(&plan, Verdict.alreadyJoined, candidate, told)
                    continue
                }

                if let hit = blockage {
                    let node = made + Int64(plan.bridges.count) * 2
                    plan.bridges.append(RepairPlan.Bridge(
                        node: node, lat: qlat, lon: qlon, end: ref, word: hit.word,
                        height: hit.height, length: distance,
                        middle: ((network.lat[at] + qlat) / 2, (network.lon[at] + qlon) / 2),
                        way: candidate.otherWay, segment: Int32(segment - otherRange.lowerBound),
                        along: along))
                    plan.inserts[candidate.otherWay, default: []].append(
                        (after: network.refs[segment],
                         segment: Int32(segment - otherRange.lowerBound), along: along, node: node))
                    link(&graph, ref, ends, (qlat, qlon), (alat, alon), (blat, blon))
                    note(&plan, Verdict.bridged(hit.word), candidate, told)
                    continue
                }

                // Two ends reaching for each other: give them one node instead of two, so
                // the join is a plain shared node and neither line grows a vertex.
                if let partner = loosePartner(of: (plat, plon), segment: segment,
                                              otherRange: otherRange, other: other,
                                              loose: loose, plan: plan, kx: kx) {
                    // A node already put in place holds two lines together; moving it
                    // again would drag one of them off its course.
                    if distance > Self.touching && plan.moves[ref] == nil {
                        plan.moves[ref] = ((plat + network.lat[partner.point]) / 2,
                                           (plon + network.lon[partner.point]) / 2)
                    }
                    plan.merges[partner.ref] = ref
                    graph.adopt(partner.ref, into: ref)
                    note(&plan, Verdict.joined, candidate, told)
                    continue
                }

                // A node an earlier repair has moved is no longer where this candidate found
                // it; handing it to a third line would drag that line over.
                if plan.moves[ref] != nil {
                    let (away, t) = RoadRepair.project(plat, plon, alat, alon, blat, blon, kx)
                    if away > Self.touching {
                        note(&plan, Verdict.wouldPull, candidate, told)
                        continue
                    }
                    qlat = plat; qlon = plon; along = t
                } else if distance > Self.touching {
                    plan.moves[ref] = (qlat, qlon)
                }
                plan.inserts[candidate.otherWay, default: []].append(
                    (after: network.refs[segment],
                     segment: Int32(segment - otherRange.lowerBound), along: along, node: ref))
                link(&graph, ref, ends, (qlat, qlon), (alat, alon), (blat, blon))
                note(&plan, Verdict.joined, candidate, told)
            }
        }

        // Flatten any chain, so one substitution in the writer is enough.
        for (gone, first) in plan.merges {
            var stands = first
            while let next = plan.merges[stands] { stands = next }
            plan.merges[gone] = stands
        }
        return plan
    }

    /// The other line's own loose end, when the segment's near node is one: an end not
    /// yet moved or merged, within reach. Joining two such ends means one shared node
    /// rather than a new vertex on either line.
    private func loosePartner(of place: (lat: Double, lon: Double), segment: Int,
                              otherRange: Range<Int>, other: Int, loose: [Bool],
                              plan: RepairPlan, kx: Double) -> (point: Int, ref: Int64)? {
        for point in [segment, segment + 1] {
            let isEnd = point == otherRange.lowerBound || point == otherRange.upperBound - 1
            let slot = other * 2 + (point == otherRange.lowerBound ? 0 : 1)
            let candidateRef = network.refs[point]
            let dx = (network.lon[point] - place.lon) * kx
            let dy = (network.lat[point] - place.lat) * RoadRepair.metresPerDegree
            if isEnd, loose[slot], plan.moves[candidateRef] == nil,
               plan.merges[candidateRef] == nil,
               (dx * dx + dy * dy).squareRoot() <= limit {
                return (point, candidateRef)
            }
        }
        return nil
    }

    /// Counts a verdict and records it against the candidate that earned it.
    private func note(_ plan: inout RepairPlan, _ reason: String,
                      _ candidate: RoadRepair.Candidate, _ told: Int) {
        plan.counts[reason, default: 0] += 1
        guard plan.trace.count == told else { return }
        plan.trace.append(String(format: "%ld %ld %.3f %@",
                                 network.wayID[Int(candidate.way)],
                                 network.wayID[Int(candidate.otherWay)],
                                 candidate.distance, reason))
    }

    /// Whether the way is still within `reach` metres of the other line thirty metres back
    /// from its end, which separates a pavement from a switchback arriving shallow.
    private func stillBeside(candidate: RoadRepair.Candidate, at: Int, kx: Double,
                             reach: Double, segment: Int) -> Bool {
        let way = Int(candidate.way)
        let lo = Int(network.start[way]), hi = Int(network.start[way + 1])
        var i = at
        let step = candidate.atEnd ? -1 : 1
        var travelled = 0.0
        var plat = network.lat[i], plon = network.lon[i]
        while i + step >= lo, i + step < hi, travelled < 30 {
            i += step
            let nlat = network.lat[i], nlon = network.lon[i]
            let dx = (nlon - plon) * kx, dy = (nlat - plat) * RoadRepair.metresPerDegree
            travelled += (dx * dx + dy * dy).squareRoot()
            plat = nlat; plon = nlon
        }
        // A stub too short to judge is refused.
        if travelled < 10 { return true }
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
    private func stopped(at p: (lat: Double, lon: Double), reaching q: (lat: Double, lon: Double),
                         distance: Double, obstacles: [Int64: [Int32]], cell: Double,
                         candidate: RoadRepair.Candidate, at: Int, segment: Int) -> Gate {
        var blocked = blockedBy(p.lat, p.lon, q.lat, q.lon, grid: obstacles, cell: cell)
        if let hit = blocked, hit.kind.isImpassable {
            return .refused(Verdict.stoppedBy(hit.kind == .building ? "building" : "fence"))
        }
        if let hit = blocked, !bridging { return .refused(Verdict.stoppedBy(hit.word)) }
        if let hit = blocked, hit.height.isFinite, Double(hit.height) > Self.tooHigh {
            return .refused(Verdict.tooHigh(hit.word, Self.tooHigh))
        }

        // A pavement running alongside a road is not a junction, however close it comes.
        let kx = RoadRepair.metresPerDegree * cos(p.lat * .pi / 180)
        let neighbour = candidate.atEnd ? at - 1 : at + 1
        let v1 = ((p.lon - network.lon[neighbour]) * kx,
                  (p.lat - network.lat[neighbour]) * RoadRepair.metresPerDegree)
        let v2 = ((network.lon[segment + 1] - network.lon[segment]) * kx,
                  (network.lat[segment + 1] - network.lat[segment]) * RoadRepair.metresPerDegree)
        let n1 = (v1.0 * v1.0 + v1.1 * v1.1).squareRoot()
        let n2 = (v2.0 * v2.0 + v2.1 * v2.1).squareRoot()
        if n1 > 0 && n2 > 0 {
            let cosine = abs(v1.0 * v2.0 + v1.1 * v2.1) / (n1 * n2)
            let angle = acos(max(-1, min(1, cosine))) * 180 / .pi
            // The arrival angle alone cannot tell a pavement from a switchback, both
            // arriving shallow, so a shallow angle counts as alongside only when the way
            // is still beside the other line thirty metres back.
            if angle < 20 && candidate.along > 0.02 && candidate.along < 0.98,
               stillBeside(candidate: candidate, at: at, kx: kx,
                           reach: distance + limit, segment: segment) {
                return .refused(Verdict.alongside)
            }
        }

        if let reason = groundSays(p.lat, p.lon, q.lat, q.lon, distance: distance) {
            if !bridging { return .refused(Verdict.stoppedBy(reason)) }
            if blocked == nil {
                blocked = Blockage(kind: reason == "ravine" ? .ravine : .cliff,
                                   word: reason, height: .nan)
            }
        }
        return .allowed(blocked)
    }

    /// Tells the graph what was just done, so later candidates judge the map as this repair
    /// leaves it: without it, a row of ends reaching for one line each sees no route.
    private func link(_ graph: inout LocalGraph, _ node: Int64, _ ends: (Int64, Int64),
                      _ q: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) {
        let kq = RoadRepair.metresPerDegree * cos(q.0 * .pi / 180)
        for (ref, point) in [(ends.0, a), (ends.1, b)] {
            let dx = (point.1 - q.1) * kq, dy = (point.0 - q.0) * RoadRepair.metresPerDegree
            graph.link(node, ref, (dx * dx + dy * dy).squareRoot())
        }
    }

    /// The first thing standing between the two points, and how high it is if OSM says.
    private func blockedBy(_ plat: Double, _ plon: Double, _ qlat: Double, _ qlon: Double,
                           grid: [Int64: [Int32]], cell: Double) -> Blockage? {
        let here = RoadRepair.key(plat, plon, cell)
        for dy in -1...1 {
            for dx in -1...1 {
                guard let bucket = grid[here &+ (Int64(dy) << 32) &+ Int64(dx)] else { continue }
                for entry in bucket {
                    let a = Int(entry)
                    if Self.crosses((plat, plon), (qlat, qlon),
                                    (network.obstacleLat[a], network.obstacleLon[a]),
                                    (network.obstacleLat[a + 1], network.obstacleLon[a + 1])) {
                        let obstacle = network.obstacleOwning(point: a)
                        return Blockage(
                            kind: ObstacleKind(rawValue: network.obstacleKind[obstacle]) ?? .barrier,
                            word: network.vocabulary[Int(network.obstacleWord[obstacle])],
                            height: network.obstacleHeight[obstacle])
                    }
                }
            }
        }
        return nil
    }

    /// Why the ground argues against joining, if it does.
    private func groundSays(_ plat: Double, _ plon: Double, _ qlat: Double, _ qlon: Double,
                            distance: Double) -> String? {
        guard let terrain, distance > 2.0 else { return nil }
        guard let here = terrain.elevation(plat, plon),
              let there = terrain.elevation(qlat, qlon) else { return nil }
        if abs(here - there) > Self.step { return "drop" }
        if let middle = terrain.elevation((plat + qlat) / 2, (plon + qlon) / 2),
           min(here, there) - middle > Self.dip { return "ravine" }
        if let steep = terrain.slope(plat, plon), steep > Self.cliffDegrees { return "face" }
        return nil
    }

    /// Obstacles are filed only in the cells a candidate stands in: a region carries
    /// millions of fences, of which few are anywhere near a gap.
    private func obstacleGrid(near candidates: [RoadRepair.Candidate], cell: Double) -> [Int64: [Int32]] {
        var wanted = Set<Int64>()
        for candidate in candidates {
            let range = network.points(of: Int(candidate.way))
            let at = candidate.atEnd ? range.upperBound - 1 : range.lowerBound
            let here = RoadRepair.key(network.lat[at], network.lon[at], cell)
            for dy in -1...1 {
                for dx in -1...1 { wanted.insert(here &+ (Int64(dy) << 32) &+ Int64(dx)) }
            }
        }

        // The point index is the payload: it names the segment without a second lookup
        // and without a cap on how many points one obstacle may have.
        var grid: [Int64: [Int32]] = [:]
        for obstacle in 0..<network.obstacleCount {
            let points = network.obstaclePoints(of: obstacle)
            guard points.count >= 2 else { continue }
            for a in points.lowerBound..<(points.upperBound - 1) {
                RoadRepair.cells(network.obstacleLat[a], network.obstacleLon[a],
                                 network.obstacleLat[a + 1], network.obstacleLon[a + 1], cell) { key in
                    if wanted.contains(key) { grid[key, default: []].append(Int32(a)) }
                }
            }
        }
        return grid
    }

    /// How far off a line a point may be and still count as sitting on it: two centimetres,
    /// the grid the coordinates live on, a PBF storing them to 1e-7 of a degree.
    private static let grazing = 2e-7

    /// Whether the two segments properly cross. A point exactly on the line counts as on
    /// the near side, so a fence starting on a road node blocks nothing; the dead band
    /// keeps the sign of the cross product stable within the coordinate grid.
    static func crosses(_ p: (Double, Double), _ q: (Double, Double),
                        _ a: (Double, Double), _ b: (Double, Double)) -> Bool {
        func beyond(_ o: (Double, Double), _ u: (Double, Double), _ v: (Double, Double)) -> Bool {
            let cross = (u.1 - o.1) * (v.0 - o.0) - (u.0 - o.0) * (v.1 - o.1)
            let span = ((u.0 - o.0) * (u.0 - o.0) + (u.1 - o.1) * (u.1 - o.1)).squareRoot()
            return cross > grazing * span
        }
        return beyond(a, b, p) != beyond(a, b, q) && beyond(p, q, a) != beyond(p, q, b)
    }
}

extension RoadRepair {
    /// Every grid cell a segment passes through. Filing a segment under its first point
    /// alone hides the long ones, whose middles are then never looked at.
    static func cells(_ alat: Double, _ alon: Double, _ blat: Double, _ blon: Double,
                      _ cell: Double, _ body: (Int64) -> Void) {
        let steps = Int(max(abs(blat - alat), abs(blon - alon)) / cell) + 1
        var last: Int64 = .min
        for step in 0...steps {
            let u = Double(step) / Double(steps)
            let here = key(alat + u * (blat - alat), alon + u * (blon - alon), cell)
            if here != last {
                last = here
                body(here)
            }
        }
    }

    static func key(_ lat: Double, _ lon: Double, _ cell: Double) -> Int64 {
        let y = Int64((lat / cell).rounded(.down))
        let x = Int64((lon / cell).rounded(.down))
        // x biased to the middle of its 32 bits: neighbour cells are probed by adding ±1
        // to the packed key, and an unbiased x of 0 or -1 borrows into the latitude half.
        return y << 32 | ((x &+ 0x8000_0000) & 0xFFFF_FFFF)
    }
}

/// What the repair decided to do to the file: four kinds of change and no others — a node
/// moves, a way takes a node into its list, one node stands in for another, and a link is
/// drawn where something was in the way. Nothing here removes anything.
struct RepairPlan {
    /// Node id to where it now sits.
    var moves: [Int64: (lat: Double, lon: Double)] = [:]
    /// Way index to the nodes it must take in: each after the node that starts its segment,
    /// and where along it. By node id rather than position, the planning network having
    /// dropped points the extract lacks; the segment index is a hint for a closed way.
    var inserts: [Int32: [(after: Int64, segment: Int32, along: Double, node: Int64)]] = [:]
    /// Node id to the node that now stands for it.
    var merges: [Int64: Int64] = [:]
    var bridges: [Bridge] = []
    var counts: [String: Int] = [:]
    /// One line per candidate, in order: what was decided and why. For comparison against
    /// the reference implementation.
    var trace: [String] = []

    struct Bridge {
        var node: Int64                     // the invented node, on the other line
        var lat: Double
        var lon: Double
        var end: Int64                      // the loose end it reaches back to
        var word: String
        var height: Float
        var length: Double
        var middle: (lat: Double, lon: Double)
        var way: Int32                      // the way that takes `node` into its list
        var segment: Int32
        var along: Double
    }
}
