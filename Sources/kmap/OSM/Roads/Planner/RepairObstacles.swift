import Foundation

/// What a link may not cross: the obstacle grid around the candidates, and the crossing test.
extension RepairPlanner {
    /// The first thing standing between the two points, and how high it is if OSM says.
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
