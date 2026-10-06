import Foundation

/// What a link may not cross: the obstacle grid around the candidates, and the crossing test.
extension RepairPlanner {
    /// The strictest thing standing between the 2 points, and how high it is if OSM says:
    /// a building or fence over anything lower, then the tallest. The first found would
    /// let a kerb listed before a fence carry a path through the fence.
    func blockedBy(
        _ plat: Double,
        _ plon: Double,
        _ qlat: Double,
        _ qlon: Double,
        grid: CellTable,
        cell: Double
    ) -> Blockage? {
        let here = RoadRepair.key(plat, plon, cell)
        let span = RoadRepair.span(limit, cell: cell, lat: plat)
        var worst: Blockage?
        for dy in -span.dy...span.dy {
            for dx in -span.dx...span.dx {
                for entry in grid.run(RoadRepair.neighbour(of: here, dy: dy, dx: dx)) {
                    let a = Int(entry)
                    guard
                        Self.crosses(
                            (plat, plon),
                            (qlat, qlon),
                            (network.obstacleLat[a], network.obstacleLon[a]),
                            (network.obstacleLat[a + 1], network.obstacleLon[a + 1])
                        )
                    else { continue }
                    let obstacle = network.obstacleOwning(point: a)
                    let found = Blockage(
                        kind: ObstacleKind(rawValue: network.obstacleKind[obstacle]) ?? .barrier,
                        word: network.vocabulary[Int(network.obstacleWord[obstacle])],
                        height: network.obstacleHeight[obstacle]
                    )
                    // Nothing outranks what may not be crossed at all.
                    if found.kind.isImpassable { return found }
                    if worst.map({ Self.higher(found, than: $0) }) ?? true { worst = found }
                }
            }
        }
        return worst
    }

    /// The obstacles passing through this very point: a gate in a fence, or a corner of a
    /// building. Such a node is the obstacle's as well as the road's.
    ///
    /// With `closing`, only what shuts the point off: a line that merely starts or stops
    /// there is not a gate in it, unless a second one meets it there, the 2 then framing
    /// an opening. A building's corner and a gate drawn as a line always count.
    func obstaclesThrough(
        _ lat: Double,
        _ lon: Double,
        grid: CellTable,
        cell: Double,
        closing: Bool = false
    ) -> [(kind: ObstacleKind, word: String)] {
        var found: [(kind: ObstacleKind, word: String)] = []
        var ends: [Int: (kind: ObstacleKind, word: String)] = [:]
        for entry in grid.run(RoadRepair.key(lat, lon, cell)) {
            let a = Int(entry)
            for at in [a, a + 1]
            where abs(network.obstacleLat[at] - lat) <= Self.grazing
                && abs(network.obstacleLon[at] - lon) <= Self.grazing
            {
                let obstacle = network.obstacleOwning(point: a)
                let hit = (
                    kind: ObstacleKind(rawValue: network.obstacleKind[obstacle]) ?? .barrier,
                    word: network.vocabulary[Int(network.obstacleWord[obstacle])]
                )
                if closing, hit.kind != .building, !Self.gateWords.contains(hit.word), isOpenEnd(at, of: obstacle) {
                    ends[obstacle] = hit
                } else {
                    found.append(hit)
                }
            }
        }
        if ends.count > 1 { found += ends.values }
        return found
    }

    /// Whether `point` is the first or last of a line that does not close on itself.
    private func isOpenEnd(_ point: Int, of obstacle: Int) -> Bool {
        let points = network.obstaclePoints(of: obstacle)
        let first = points.lowerBound, last = points.upperBound - 1
        guard point == first || point == last else { return false }
        return network.obstacleLat[first] != network.obstacleLat[last]
            || network.obstacleLon[first] != network.obstacleLon[last]
    }

    func isObstacleVertex(_ lat: Double, _ lon: Double, grid: CellTable, cell: Double) -> Bool {
        !obstaclesThrough(lat, lon, grid: grid, cell: cell).isEmpty
    }

    /// Whether `a` stands taller than `b`: a known height over an unknown one.
    private static func higher(_ a: Blockage, than b: Blockage) -> Bool {
        guard a.height.isFinite else { return false }
        return !b.height.isFinite || a.height > b.height
    }

    /// Obstacles are filed only in the cells a candidate stands in: a region carries
    /// millions of fences, of which few are anywhere near a gap.
    func obstacleGrid(near candidates: [RoadRepair.Candidate]) -> CellTable {
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

    /// How far off a line a point may be and still count as sitting on it: 2 centimetres,
    /// the grid the coordinates live on, a PBF storing them to 1e-7 of a degree.
    private static let grazing = 2e-7

    /// Whether the link from `p` to `q` crosses the obstacle segment from `a` to `b`. A touch
    /// at the link's own ends is not a crossing: a road ending at a gate in a fence or a door
    /// in a wall starts on it. An obstacle point on the link between its ends is one. The dead
    /// band keeps a point's side stable within the coordinate grid.
    static func crosses(
        _ p: (Double, Double),
        _ q: (Double, Double),
        _ a: (Double, Double),
        _ b: (Double, Double)
    ) -> Bool {
        func side(_ o: (Double, Double), _ u: (Double, Double), _ v: (Double, Double)) -> Int {
            let cross = (u.1 - o.1) * (v.0 - o.0) - (u.0 - o.0) * (v.1 - o.1)
            let span = ((u.0 - o.0) * (u.0 - o.0) + (u.1 - o.1) * (u.1 - o.1)).squareRoot()
            if cross > grazing * span { return 1 }
            if cross < -grazing * span { return -1 }
            return 0
        }
        // Asked first, as most segments near a gap lie wholly to 1 side of it.
        let sa = side(p, q, a), sb = side(p, q, b)
        if sa * sb > 0 { return false }
        // The obstacle drawn across the gap itself, end to end: a gate mapped as a way
        // between the 2 roads stands in it.
        func same(_ u: (Double, Double), _ v: (Double, Double)) -> Bool {
            abs(u.0 - v.0) <= grazing && abs(u.1 - v.1) <= grazing
        }
        if sa == 0, sb == 0, (same(a, p) && same(b, q)) || (same(a, q) && same(b, p)) { return true }
        let sp = side(a, b, p), sq = side(a, b, q)
        if sp * sq < 0 && sa * sb < 0 { return true }
        // An obstacle point on the link itself, away from both of its ends.
        func onLink(_ x: (Double, Double)) -> Bool {
            let dx = q.0 - p.0, dy = q.1 - p.1
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return false }
            let along = ((x.0 - p.0) * dx + (x.1 - p.1) * dy) / length
            return along > grazing && along < length - grazing
        }
        return (sa == 0 && onLink(a)) || (sb == 0 && onLink(b))
    }
}
