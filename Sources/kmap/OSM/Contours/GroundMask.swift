import Foundation

/// The union of region outlines, rasterized so that a point test is one bit lookup rather
/// than a ray cast against every polygon edge. Grown outward by a margin first: extracts
/// are cut a shade generously, and a contour should meet the data's edge rather than stop
/// short of it.
struct GroundMask {
    /// About 550 m of cell at the equator: fine enough that the cut follows the border,
    /// coarse enough that a country is a few megabits.
    private static let preferredCell = 0.005
    /// The ceiling on the table. A build spanning a continent coarsens its cells to fit
    /// rather than asking for a gigabyte of mask.
    private static let mostCells = 16_000_000
    /// How far past the outline the mask reaches, in degrees.
    static let margin = 0.05
    /// A run of fewer points is not a line.
    private static let fewestLinePoints = 2

    private var bits: [Bool]
    private var columns = 0, rows = 0
    private var minLon = 0.0, minLat = 0.0
    private var cell = GroundMask.preferredCell

    init?(rings: [RegionOutline.Ring]) {
        let adds = rings.filter { !$0.subtract }
        guard !adds.isEmpty else { return nil }
        var loLon = Double.infinity, loLat = Double.infinity
        var hiLon = -Double.infinity, hiLat = -Double.infinity
        for ring in adds {
            for p in ring.points {
                loLon = min(loLon, p.lon); hiLon = max(hiLon, p.lon)
                loLat = min(loLat, p.lat); hiLat = max(hiLat, p.lat)
            }
        }
        guard loLon < hiLon, loLat < hiLat else { return nil }
        loLon -= Self.margin; loLat -= Self.margin
        hiLon += Self.margin; hiLat += Self.margin

        cell = Self.preferredCell
        while ((hiLon - loLon) / cell) * ((hiLat - loLat) / cell) > Double(Self.mostCells) {
            cell *= 2
        }
        minLon = loLon; minLat = loLat
        columns = max(1, Int(((hiLon - loLon) / cell).rounded(.up)))
        rows = max(1, Int(((hiLat - loLat) / cell).rounded(.up)))
        bits = [Bool](repeating: false, count: columns * rows)

        // Scanline fill, even-odd, one ring at a time: additive rings set, holes clear.
        // Holes go last so a hole is a hole whatever order the file listed them in.
        for pass in [false, true] {
            for ring in rings where ring.subtract == pass {
                fill(ring, value: !ring.subtract)
            }
        }

        // Grown outward by the margin, separably: a run along each row, then each column.
        let reach = max(1, Int((Self.margin / cell).rounded()))
        dilate(by: reach)
    }

    private mutating func fill(_ ring: RegionOutline.Ring, value: Bool) {
        let pts = ring.points
        guard pts.count >= RegionOutline.fewestRingPoints else { return }
        for row in 0..<rows {
            // Sampled at the centre of the row.
            let lat = minLat + (Double(row) + 0.5) * cell
            var crossings: [Double] = []
            var j = pts.count - 1
            for i in 0..<pts.count {
                let a = pts[j], b = pts[i]
                j = i
                if (a.lat > lat) == (b.lat > lat) { continue }
                crossings.append(a.lon + (b.lon - a.lon) * (lat - a.lat) / (b.lat - a.lat))
            }
            crossings.sort()
            var k = 0
            while k + 1 < crossings.count {
                let from = max(0, Int(((crossings[k] - minLon) / cell).rounded(.down)))
                let to = min(columns - 1, Int(((crossings[k + 1] - minLon) / cell).rounded(.up)))
                if from <= to {
                    for column in from...to { bits[row * columns + column] = value }
                }
                k += 2
            }
        }
    }

    private mutating func dilate(by reach: Int) {
        var out = bits
        for row in 0..<rows {
            let base = row * columns
            for column in 0..<columns where bits[base + column] {
                for d in max(0, column - reach)...min(columns - 1, column + reach) {
                    out[base + d] = true
                }
            }
        }
        bits = out
        for column in 0..<columns {
            for row in 0..<rows where out[row * columns + column] {
                for d in max(0, row - reach)...min(rows - 1, row + reach) {
                    bits[d * columns + column] = true
                }
            }
        }
    }

    func contains(lat: Double, lon: Double) -> Bool {
        let column = Int(((lon - minLon) / cell).rounded(.down))
        let row = Int(((lat - minLat) / cell).rounded(.down))
        guard column >= 0, column < columns, row >= 0, row < rows else { return false }
        return bits[row * columns + column]
    }

    /// The lines, cut where they leave the region: each line becomes its runs of points on
    /// covered ground, and a line with no such run is not drawn at all. A closed ring that
    /// survives whole stays closed; one that is cut is open pieces from then on.
    func clip(_ lines: [Contours.Line]) -> [Contours.Line] {
        var out: [Contours.Line] = []
        for line in lines {
            var run: [(lat: Double, lon: Double)] = []
            var cut = false
            for point in line.points {
                if contains(lat: point.lat, lon: point.lon) {
                    run.append(point)
                } else {
                    cut = true
                    if run.count >= Self.fewestLinePoints {
                        out.append(Contours.Line(elevation: line.elevation,
                                                 points: run, closed: false))
                    }
                    run.removeAll(keepingCapacity: true)
                }
            }
            if run.count >= Self.fewestLinePoints {
                out.append(Contours.Line(elevation: line.elevation, points: run,
                                         closed: line.closed && !cut))
            }
        }
        return out
    }
}
