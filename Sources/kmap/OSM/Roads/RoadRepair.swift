import Foundation

/// Finding the road ends OSM left short of the line they were drawn for.
///
/// The loose ends are gridded rather than the segments, two orders of magnitude fewer
/// entries, and every segment is streamed past that grid.
struct RoadRepair {
    static let metresPerDegree = 111320.0

    /// Grid cell for filing the loose ends: about 55 m of latitude, comfortably wider
    /// than any gap worth closing.
    static let cellDegrees = 0.0005

    /// 2 ends per way.
    static let endsPerWay = 2

    /// A guess at how many ways have a loose end, for the candidates' capacity.
    private static let looseShare = 4

    /// Metres per degree of longitude at a latitude.
    static func metresPerLonDegree(at lat: Double) -> Double {
        metresPerDegree * cos(lat * .pi / 180)
    }

    /// A candidate: an end of a way, and the nearest line it stops short of.
    struct Candidate {
        var way: Int32
        var atEnd: Bool  // false: the way's first point
        var otherWay: Int32 = -1
        var segment: Int32 = -1
        var distance: Double = .infinity
        var along: Double = 0  // where on that segment the end lands, 0...1
    }

    let network: RoadNetwork
    let limit: Double

    /// Which of a way's two ends belong to no other routable way, and so may be loose.
    /// The node ids are already in a flat array, so they are sorted and counted rather
    /// than gathered into a dictionary.
    static func looseEnds(of network: RoadNetwork) -> [Bool] {
        var sorted = network.refs
        IDSort.sort(&sorted)
        var loose = [Bool](repeating: false, count: network.wayCount * Self.endsPerWay)
        let ways = network.wayCount
        loose.withUnsafeMutableBufferPointer { loose in
            sorted.withUnsafeBufferPointer { sorted in
                // Each lane answers for its own ways' slots.
                nonisolated(unsafe) let loose = loose, sorted = sorted
                let perLane = Self.waysPerLane
                DispatchQueue.concurrentPerform(iterations: (ways + perLane - 1) / perLane) { lane in
                    for way in lane * perLane..<min(ways, (lane + 1) * perLane) {
                        let range = network.points(of: way)
                        for (slot, point) in [range.lowerBound, range.upperBound - 1].enumerated() {
                            loose[way * Self.endsPerWay + slot] = Self.appearsOnce(network.refs[point], in: sorted)
                        }
                    }
                }
            }
        }
        return loose
    }

    /// Ways handed to a core at a time.
    private static let waysPerLane = 1 << 14

    /// Whether an id is in the list exactly once -- which is what makes an end loose.
    /// Counting the rest of a repeated id says nothing more.
    private static func appearsOnce(_ id: Int64, in sorted: UnsafeBufferPointer<Int64>) -> Bool {
        var low = 0, high = sorted.count
        while low < high {  // first index not less than id
            let mid = (low + high) / 2
            if sorted[mid] < id { low = mid + 1 } else { high = mid }
        }
        guard low < sorted.count, sorted[low] == id else { return false }
        return low + 1 >= sorted.count || sorted[low + 1] != id
    }

    /// Every loose end that stops within `limit` of another line, with that line named,
    /// and the loose-end test itself, which the planner needs again for its partners.
    ///
    /// Bands of latitude, an equal share of the ends each, are worked on side by side. An
    /// end is filed only in its own band, so 1 band alone writes it; and it meets the same
    /// segments in the same order as a single walk would, so it keeps the same nearest line.
    func candidates() -> (found: [Candidate], loose: [Bool]) {
        let loose = Self.looseEnds(of: network)
        var ends = Self.looseCandidates(loose, ways: network.wayCount)
        guard !ends.isEmpty else { return ([], loose) }
        let homeRows = ends.map { Self.row(point(of: $0).lat, Self.cellDegrees) }
        let cuts = Self.bandCuts(homeRows)
        let tables = bandTables(ends, homeRows: homeRows, cuts: cuts)
        probeBands(&ends, cuts: cuts, tables: tables)
        // An end that met no line keeps an infinite distance and no segment.
        return (ends.filter { $0.segment >= 0 && $0.distance <= limit }, loose)
    }

    /// A candidate for every loose end, nearest line still unknown.
    private static func looseCandidates(_ loose: [Bool], ways: Int) -> [Candidate] {
        var ends: [Candidate] = []
        ends.reserveCapacity(ways / looseShare)
        for way in 0..<ways {
            if loose[way * endsPerWay] { ends.append(Candidate(way: Int32(way), atEnd: false)) }
            if loose[way * endsPerWay + 1] { ends.append(Candidate(way: Int32(way), atEnd: true)) }
        }
        return ends
    }

    /// The first row of each band, then `Int64.max`: cut where the ends' rows divide
    /// into equal shares, a band never empty.
    private static func bandCuts(_ homeRows: [Int64]) -> [Int64] {
        let ordered = homeRows.sorted()
        let bandCount = min(ordered.count, Machine.cores * bandsPerCore)
        var cuts: [Int64] = []
        for band in 0..<bandCount {
            let cut = ordered[band * ordered.count / bandCount]
            if cuts.last != cut { cuts.append(cut) }
        }
        cuts.append(.max)
        return cuts
    }

    /// Each band's ends, filed into their own cell and the 8 around it, so a segment finds
    /// every end within reach with 1 probe rather than 9.
    private func bandTables(_ ends: [Candidate], homeRows: [Int64], cuts: [Int64]) -> [CellTable] {
        let bands = cuts.count - 1
        var keys = [[Int64]](repeating: [], count: bands)
        var owners = [[Int32]](repeating: [], count: bands)
        for (i, end) in ends.enumerated() {
            var band = 0
            while homeRows[i] >= cuts[band + 1] { band += 1 }
            let point = point(of: end)
            let home = Self.key(point.lat, point.lon, Self.cellDegrees)
            for dy in -1...1 {
                for dx in -1...1 {
                    keys[band].append(Self.neighbour(of: home, dy: dy, dx: dx))
                    owners[band].append(Int32(i))
                }
            }
        }
        return (0..<bands).map { CellTable(keys: keys[$0], values: owners[$0]) }
    }

    /// Every band offers every segment that can reach it to its own ends, side by side.
    private func probeBands(_ ends: inout [Candidate], cuts: [Int64], tables: [CellTable]) {
        let (lowRow, highRow) = wayRows(Self.cellDegrees)
        ends.withUnsafeMutableBufferPointer { ends in
            lowRow.withUnsafeBufferPointer { lowRow in
                highRow.withUnsafeBufferPointer { highRow in
                    // A band writes only the ends filed in it; the rest is read alone.
                    nonisolated(unsafe) let ends = ends, lowRow = lowRow, highRow = highRow
                    DispatchQueue.concurrentPerform(iterations: tables.count) { band in
                        // A segment reaching an end's cells passes within 1 row of it; 1
                        // more row allows for rounding on the way.
                        let low = cuts[band] - Self.rowSlack
                        let high = cuts[band + 1] == .max ? .max : cuts[band + 1] + Self.rowSlack
                        for way in 0..<network.wayCount where highRow[way] >= low && lowRow[way] <= high {
                            probe(way: way, grid: tables[band], ends: ends)
                        }
                    }
                }
            }
        }
    }

    /// Offers every segment of a way to the ends near it.
    private func probe(way: Int, grid: CellTable, ends: UnsafeMutableBufferPointer<Candidate>) {
        let range = network.points(of: way)
        let level = network.level[way]
        for i in range.lowerBound..<(range.upperBound - 1) {
            probe(way: Int32(way), segment: i, level: level, cell: Self.cellDegrees, grid: grid, ends: ends)
        }
    }

    /// Bands per core, so an uneven band does not leave the others idle.
    private static let bandsPerCore = 4
    /// Rows of cells a band looks past its own edges.
    private static let rowSlack: Int64 = 2

    /// The cell row a latitude falls in, as `key` counts rows.
    private static func row(_ lat: Double, _ cell: Double) -> Int64 {
        Int64((lat / cell).rounded(.down))
    }

    /// The lowest and highest cell row each way's points reach.
    private func wayRows(_ cell: Double) -> ([Int64], [Int64]) {
        let ways = network.wayCount
        var low = [Int64](repeating: 0, count: ways)
        var high = [Int64](repeating: 0, count: ways)
        low.withUnsafeMutableBufferPointer { low in
            high.withUnsafeMutableBufferPointer { high in
                // Each lane fills its own ways' slots.
                nonisolated(unsafe) let low = low, high = high
                let perLane = Self.waysPerLane
                DispatchQueue.concurrentPerform(iterations: (ways + perLane - 1) / perLane) { lane in
                    for way in lane * perLane..<min(ways, (lane + 1) * perLane) {
                        var least = Int64.max, most = Int64.min
                        for point in network.points(of: way) {
                            let row = Self.row(network.lat[point], cell)
                            least = min(least, row)
                            most = max(most, row)
                        }
                        low[way] = least
                        high[way] = most
                    }
                }
            }
        }
        return (low, high)
    }

    private func point(of end: Candidate) -> (lat: Double, lon: Double) {
        let range = network.points(of: Int(end.way))
        let at = end.atEnd ? range.upperBound - 1 : range.lowerBound
        return (network.lat[at], network.lon[at])
    }

    /// Offer one segment to every loose end near it, keeping each end's nearest.
    private func probe(
        way: Int32,
        segment: Int,
        level: Int32,
        cell: Double,
        grid: CellTable,
        ends: UnsafeMutableBufferPointer<Candidate>
    ) {
        let alat = network.lat[segment], alon = network.lon[segment]
        let blat = network.lat[segment + 1], blon = network.lon[segment + 1]
        let steps = max(Int(max(abs(blat - alat), abs(blon - alon)) / cell), 0) + 1
        var visited: Int64 = .min
        for step in 0...steps {
            let u = Double(step) / Double(steps)
            let here = Self.key(alat + u * (blat - alat), alon + u * (blon - alon), cell)
            if here == visited { continue }
            visited = here
            for index in grid.run(here) {
                consider(
                    end: Int(index),
                    way: way,
                    segment: segment,
                    level: level,
                    alat: alat,
                    alon: alon,
                    blat: blat,
                    blon: blon,
                    ends: ends
                )
            }
        }
    }

    private func consider(
        end index: Int,
        way: Int32,
        segment: Int,
        level: Int32,
        alat: Double,
        alon: Double,
        blat: Double,
        blon: Double,
        ends: UnsafeMutableBufferPointer<Candidate>
    ) {
        var end = ends[index]
        guard end.way != way, network.level[Int(end.way)] == level else { return }
        let range = network.points(of: Int(end.way))
        let at = end.atEnd ? range.upperBound - 1 : range.lowerBound
        // A line already carrying this node is not something to join it to.
        guard network.refs[at] != network.refs[segment],
            network.refs[at] != network.refs[segment + 1]
        else { return }

        let plat = network.lat[at], plon = network.lon[at]
        let kx = Self.metresPerLonDegree(at: plat)
        let (distance, along) = Self.project(plat, plon, alat, alon, blat, blon, kx)
        guard distance < end.distance else { return }
        end.distance = distance
        end.along = along
        end.otherWay = way
        end.segment = Int32(segment)
        ends[index] = end
    }

    /// Distance from a point to a segment in metres, and how far along it lands.
    static func project(
        _ plat: Double,
        _ plon: Double,
        _ alat: Double,
        _ alon: Double,
        _ blat: Double,
        _ blon: Double,
        _ kx: Double
    ) -> (Double, Double) {
        let ax = (alon - plon) * kx, ay = (alat - plat) * metresPerDegree
        let bx = (blon - plon) * kx, by = (blat - plat) * metresPerDegree
        let dx = bx - ax, dy = by - ay
        if dx == 0 && dy == 0 { return ((ax * ax + ay * ay).squareRoot(), 0) }
        let t = max(0, min(1, -(ax * dx + ay * dy) / (dx * dx + dy * dy)))
        let ox = ax + t * dx, oy = ay + t * dy
        return ((ox * ox + oy * oy).squareRoot(), t)
    }
}

extension RoadRepair {
    /// Every grid cell a segment passes through. Filing a segment under its first point
    /// alone hides the long ones, whose middles are then never looked at.
    static func cells(
        _ alat: Double,
        _ alon: Double,
        _ blat: Double,
        _ blon: Double,
        _ cell: Double,
        _ body: (Int64) -> Void
    ) {
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

    /// A cell key: the latitude cell in the high half, the longitude cell in the low.
    private static let latShift = 32
    private static let lowHalf: Int64 = 0xFFFF_FFFF
    /// x is biased to the middle of its half: the neighbour cells are probed by adding
    /// or subtracting 1, and an unbiased x of 0 or -1 would borrow into the latitude half.
    private static let lonBias: Int64 = 0x8000_0000

    static func key(_ lat: Double, _ lon: Double, _ cell: Double) -> Int64 {
        let y = Int64((lat / cell).rounded(.down))
        let x = Int64((lon / cell).rounded(.down))
        return y << latShift | ((x &+ lonBias) & lowHalf)
    }

    /// The cells either side of a point that `reach` metres can cross, at least 1 each way.
    /// A cell of longitude narrows towards the poles, so more of them are wanted there.
    static func span(_ reach: Double, cell: Double, lat: Double) -> (dy: Int, dx: Int) {
        func count(_ size: Double) -> Int {
            guard size > 0, reach > 0 else { return 1 }
            return min(Self.widestSpan, max(1, Int((reach / size).rounded(.up))))
        }
        return (count(cell * metresPerDegree), count(cell * metresPerLonDegree(at: lat)))
    }

    /// Bounds the cells looked through near a pole, where a cell is nearly no width.
    private static let widestSpan = 64

    /// The cells of size `cell` round every candidate's end, 3 by 3 each, or as many more
    /// as `reach` metres cross.
    static func cells(
        around candidates: [Candidate],
        of network: RoadNetwork,
        cell: Double,
        reach: Double = 0
    ) -> CellTable {
        var cells: [Int64] = []
        cells.reserveCapacity(candidates.count * neighbourhood)
        for candidate in candidates {
            let range = network.points(of: Int(candidate.way))
            let at = candidate.atEnd ? range.upperBound - 1 : range.lowerBound
            let here = key(network.lat[at], network.lon[at], cell)
            let span = span(reach, cell: cell, lat: network.lat[at])
            for dy in -span.dy...span.dy {
                for dx in -span.dx...span.dx { cells.append(neighbour(of: here, dy: dy, dx: dx)) }
            }
        }
        return CellTable(keys: cells)
    }

    /// Cells in the 3 by 3 round one.
    private static let neighbourhood = 9

    /// The key of the cell `dy` rows and `dx` columns away.
    static func neighbour(of key: Int64, dy: Int, dx: Int) -> Int64 {
        key &+ (Int64(dy) << latShift) &+ Int64(dx)
    }
}
