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
        // A multipolygon's shores, then its islands cut back out, then the ponds that are
        // closed ways of their own and may stand on one of those islands.
        for ring in rings where !ring.standalone && !ring.island { fill(ring, wet: true) }
        for ring in rings where ring.island { fill(ring, wet: false) }
        for ring in rings where ring.standalone { fill(ring, wet: true) }
    }

    func isWater(lat: Double, lon: Double) -> Bool {
        let row = Int(((lat - minLat) * Double(side)).rounded(.down))
        let column = Int(((lon - minLon) * Double(side)).rounded(.down))
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

        var crossings: [Double] = []
        for row in firstRow...lastRow {
            let y = minLat + (Double(row) + 0.5) / scale
            crossings.removeAll(keepingCapacity: true)
            var j = n - 1
            for i in 0..<n {
                let yi = ring.lat(i), yj = ring.lat(j)
                if (yi > y) != (yj > y) {
                    crossings.append((ring.lon(j) - ring.lon(i)) * (y - yi) / (yj - yi) + ring.lon(i))
                }
                j = i
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
            var previous: (point: (lat: Double, lon: Double), wet: Bool)?
            func close() {
                if run.count >= Self.fewestLinePoints {
                    out.append(Contours.Line(elevation: line.elevation, points: run, closed: false))
                }
                run.removeAll(keepingCapacity: true)
            }
            for point in line.points {
                let wet = isWater(lat: point.lat, lon: point.lon)
                if let previous, previous.wet != wet {
                    let shore = self.shore(dry: wet ? previous.point : point,
                                           wet: wet ? point : previous.point)
                    run.append(shore)
                    if wet { close() }
                }
                if wet { cut = true } else { run.append(point) }
                previous = (point, wet)
            }
            if run.count >= Self.fewestLinePoints {
                out.append(Contours.Line(elevation: line.elevation, points: run,
                                         closed: line.closed && !cut))
            }
        }
        return out
    }

    /// Where the segment from dry ground to water meets the shore, by halving.
    private func shore(dry: (lat: Double, lon: Double),
                       wet: (lat: Double, lon: Double)) -> (lat: Double, lon: Double) {
        var dry = dry, wet = wet
        for _ in 0..<Self.bisections {
            let middle = (lat: (dry.lat + wet.lat) / 2, lon: (dry.lon + wet.lon) / 2)
            if isWater(lat: middle.lat, lon: middle.lon) { wet = middle } else { dry = middle }
        }
        return dry
    }
}
