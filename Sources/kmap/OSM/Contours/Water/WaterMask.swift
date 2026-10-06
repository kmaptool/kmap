import Foundation

/// One degree cell's water as a raster, and the cut it makes in that cell's contours.
///
/// Rasterized so that asking a contour vertex whether it is wet is one bit lookup, however
/// many lakes the cell holds. The shoreline is then found inside the segment that crosses
/// it, so the line ends at the water rather than a vertex short of it.
struct WaterMask {
    /// Half an arc-second: about 15 m north to south, finer than any elevation grid the
    /// contours are traced from, and 6.5 MB of bits for a whole cell.
    static let cellsPerDegree = 7200
    /// How many times a crossing segment is halved to find the shore: a 30 m segment to
    /// under half a metre.
    private static let bisections = 6
    /// A run of fewer points is not a line.
    private static let fewestLinePoints = 2
    private static let bitsPerWord = 64
    private static let metresPerDegree = 111_320.0
    /// A piece with water at both ends and shorter than this is dropped: two raster cells,
    /// about 30 m, below which a notch in the shore looks like ground. A piece ending
    /// anywhere else is kept, since at a cell's edge its other half is next door.
    static let shortestBetweenShores = 2 * metresPerDegree / Double(cellsPerDegree)

    private let minLat: Double, minLon: Double
    private var words: [UInt64]
    private let side = WaterMask.cellsPerDegree

    /// Nil where the cell holds no water: there is nothing to cut, and nothing is built.
    init?(cellAt lat: Int, _ lon: Int, water: WaterBodies) {
        let rings = water.rings(inCellAt: lat, lon)
        guard !rings.isEmpty else { return nil }
        minLat = Double(lat)
        minLon = Double(lon)
        words = [UInt64](repeating: 0, count: (side * side + Self.bitsPerWord - 1) / Self.bitsPerWord)
        // A multipolygon's shores, its islands cut back out, then the ponds that are closed ways
        // of their own and may stand on those islands. Islands cut only their own multipolygon's
        // water, so one with islands is drawn on a layer of its own and joined.
        let withIslands = Set(rings.filter(\.island).map(\.group))
        for ring in rings where !ring.standalone && !ring.island && !withIslands.contains(ring.group) {
            fill(ring, wet: true)
        }
        if !withIslands.isEmpty {
            var joined = words
            for group in withIslands.sorted() {
                words = [UInt64](repeating: 0, count: joined.count)
                for ring in rings where ring.group == group && !ring.island { fill(ring, wet: true) }
                for ring in rings where ring.group == group && ring.island { fill(ring, wet: false) }
                for i in joined.indices { joined[i] |= words[i] }
            }
            words = joined
        }
        for ring in rings where ring.standalone { fill(ring, wet: true) }
    }

    func isWater(lat: Double, lon: Double) -> Bool {
        var row = Int(((lat - minLat) * Double(side)).rounded(.down))
        var column = Int(((lon - minLon) * Double(side)).rounded(.down))
        // The cell's own north and east edges, where the tracer puts nodes, are its last
        // row and column rather than past them.
        if row == side, lat - minLat == 1 { row = side - 1 }
        if column == side, lon - minLon == 1 { column = side - 1 }
        guard row >= 0, row < side, column >= 0, column < side else { return false }
        let bit = row * side + column
        return words[bit / Self.bitsPerWord] & (1 << UInt64(bit % Self.bitsPerWord)) != 0
    }

    // MARK: Filling

    /// Scanline fill, even-odd, sampled at each raster cell's centre.
    private mutating func fill(_ ring: WaterBodies.Ring, wet: Bool) {
        let n = ring.count
        guard n >= WaterBodies.fewestRingPoints else { return }
        var loLat = Double.infinity, hiLat = -Double.infinity
        for i in 0..<n { loLat = min(loLat, ring.lat(i)); hiLat = max(hiLat, ring.lat(i)) }
        let scale = Double(side)
        let firstRow = max(0, Int(((loLat - minLat) * scale).rounded(.down)))
        let lastRow = min(side - 1, Int(((hiLat - minLat) * scale).rounded(.down)))
        guard firstRow <= lastRow else { return }

        // Edges bucketed by the first row they can cross, a row of slack either side; the
        // crossing test itself is unchanged, so this only spares the edges far from the
        // row. A sea coast of a hundred thousand points against 7200 rows was the cost.
        var startsAt = [[Int]](repeating: [], count: lastRow - firstRow + 1)
        var endsAfter = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let j = i == 0 ? n - 1 : i - 1
            let lo = min(ring.lat(i), ring.lat(j)), hi = max(ring.lat(i), ring.lat(j))
            let from = max(firstRow, Int(((lo - minLat) * scale).rounded(.down)) - 1)
            let upTo = min(lastRow, Int(((hi - minLat) * scale).rounded(.up)) + 1)
            guard from <= upTo else { continue }
            startsAt[from - firstRow].append(i)
            endsAfter[i] = upTo
        }
        var active: [Int] = []
        var crossings: [Double] = []
        for row in firstRow...lastRow {
            let y = minLat + (Double(row) + 0.5) / scale
            active.append(contentsOf: startsAt[row - firstRow])
            active.removeAll { endsAfter[$0] < row }
            crossings.removeAll(keepingCapacity: true)
            for i in active {
                let j = i == 0 ? n - 1 : i - 1
                let yi = ring.lat(i), yj = ring.lat(j)
                if (yi > y) != (yj > y) {
                    crossings.append((ring.lon(j) - ring.lon(i)) * (y - yi) / (yj - yi) + ring.lon(i))
                }
            }
            guard crossings.count >= 2 else { continue }
            crossings.sort()
            var at = 0
            while at + 1 < crossings.count {
                // The cells whose centres lie between the two crossings.
                let from = max(0, Int(((crossings[at] - minLon) * scale - 0.5).rounded(.up)))
                let upTo = min(side - 1, Int(((crossings[at + 1] - minLon) * scale - 0.5).rounded(.down)))
                if from <= upTo { set(row: row, from: from, through: upTo, wet: wet) }
                at += 2
            }
        }
    }

    private mutating func set(row: Int, from: Int, through: Int, wet: Bool) {
        for column in from...through {
            let bit = row * side + column
            let mask: UInt64 = 1 << UInt64(bit % Self.bitsPerWord)
            if wet { words[bit / Self.bitsPerWord] |= mask } else { words[bit / Self.bitsPerWord] &= ~mask }
        }
    }

    // MARK: Cutting

    /// The lines with their wet stretches removed: each becomes its runs over dry ground,
    /// every run ending on the shore. A closed ring that stays dry all the way round stays
    /// closed; one that is cut is open pieces from then on.
    func clip(_ lines: [Contours.Line]) -> [Contours.Line] {
        var out: [Contours.Line] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            var run: [(lat: Double, lon: Double)] = []
            var cut = false
            var fromShore = false
            var previous: (point: (lat: Double, lon: Double), wet: Bool)?
            func close() {
                if run.count >= Self.fewestLinePoints,
                    !(fromShore && Self.length(of: run) < Self.shortestBetweenShores)
                {
                    out.append(Contours.Line(elevation: line.elevation, points: run, closed: false))
                }
                run.removeAll(keepingCapacity: true)
            }
            for point in line.points {
                let wet = isWater(lat: point.lat, lon: point.lon)
                if let previous, previous.wet != wet {
                    let shore = self.shore(
                        dry: wet ? previous.point : point,
                        wet: wet ? point : previous.point
                    )
                    run.append(shore)
                    if wet { close() } else { fromShore = true }
                }
                if wet { cut = true } else { run.append(point) }
                previous = (point, wet)
            }
            if run.count >= Self.fewestLinePoints {
                out.append(
                    Contours.Line(
                        elevation: line.elevation,
                        points: run,
                        closed: line.closed && !cut
                    )
                )
            }
        }
        return out
    }

    /// Length in metres, flat-earth: enough for runs of tens of metres.
    private static func length(of run: [(lat: Double, lon: Double)]) -> Double {
        var metres = 0.0
        for (a, b) in zip(run, run.dropFirst()) {
            let across = (b.lon - a.lon) * cos(a.lat * .pi / 180)
            metres += (across * across + (b.lat - a.lat) * (b.lat - a.lat)).squareRoot()
        }
        return metres * metresPerDegree
    }

    /// Where the segment from dry ground to water meets the shore, by halving.
    private func shore(
        dry: (lat: Double, lon: Double),
        wet: (lat: Double, lon: Double)
    ) -> (lat: Double, lon: Double) {
        var dry = dry, wet = wet
        for _ in 0..<Self.bisections {
            let middle = (lat: (dry.lat + wet.lat) / 2, lon: (dry.lon + wet.lon) / 2)
            if isWater(lat: middle.lat, lon: middle.lon) { wet = middle } else { dry = middle }
        }
        return dry
    }
}
