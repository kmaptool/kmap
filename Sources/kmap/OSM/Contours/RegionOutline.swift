import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a module of its own outside Apple's platforms.
import FoundationNetworking
#endif

/// The ground a region actually is, and the contours that belong on it. Tiles are
/// rectangles and elevation is fetched by the degree, so a build would otherwise carry
/// relief over ground no chosen region provides data for. Geofabrik publishes each
/// extract's cutting polygon as a `.poly` file, and the contours are cut to that outline.
enum RegionOutline {

    /// One ring of a `.poly` file. Osmosis marks a ring to subtract — a hole — by
    /// prefixing its name with `!`.
    struct Ring {
        var subtract: Bool
        var points: [(lon: Double, lat: Double)]
    }

    /// Parses the osmosis `.poly` format: a file-name line, then per ring a name line,
    /// coordinate pairs and END, with a final END closing the file.
    /// - Returns: nil unless at least one additive ring of three points was read.
    static func parse(_ text: String) -> [Ring]? {
        var rings: [Ring] = []
        var current: Ring?
        var seenFileName = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !seenFileName { seenFileName = true; continue }
            if line == "END" {
                if let ring = current {
                    if ring.points.count >= 3 { rings.append(ring) }
                    current = nil
                }
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if current != nil, parts.count >= 2,
               let lon = Double(parts[0]), let lat = Double(parts[1]) {
                current?.points.append((lon, lat))
            } else if current == nil {
                current = Ring(subtract: line.hasPrefix("!"), points: [])
            }
        }
        return rings.contains(where: { !$0.subtract }) ? rings : nil
    }

    /// A region's `.poly`, from the cache or from beside its extract on Geofabrik. It is
    /// the exact polygon the extract was cut with, so anything trimmed to it agrees with
    /// the data.
    static func rings(for region: Region) async -> [Ring]? {
        let cacheDir = Paths.cache.appendingPathComponent("poly", isDirectory: true)
        Paths.ensure(cacheDir)
        let file = cacheDir.appendingPathComponent("\(FileTools.slugify(region.id)).poly")
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let rings = parse(text) {
            return rings
        }
        guard let pbf = region.pbfURL,
              let polyURL = URL(string: pbf.absoluteString
                  .replacingOccurrences(of: "-latest.osm.pbf", with: ".poly")) else {
            return nil
        }
        var request = URLRequest(url: polyURL)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              let rings = parse(text) else { return nil }
        try? data.write(to: file, options: .atomic)
        return rings
    }
}

/// The union of region outlines, rasterized so that a point test is one bit lookup rather
/// than a ray cast against every polygon edge. Grown outward by a margin first: extracts
/// are cut a shade generously, and a contour should meet the data's edge rather than stop
/// short of it.
extension RegionOutline {

    /// The osmosis `.poly` text for a set of rings: the dialect `parse` reads, Geofabrik
    /// publishes and pyhgtmap's `--polygon` expects. Every ring is closed on the way out.
    static func polyText(name: String, sections: [[(lon: Double, lat: Double)]]) -> String {
        var text = "\(name)\n"
        for (index, points) in sections.enumerated() {
            text += "\(index + 1)\n"
            for point in points { text += "   \(point.lon) \(point.lat)\n" }
            if let first = points.first, let last = points.last, first != last {
                text += "   \(first.lon) \(first.lat)\n"
            }
            text += "END\n"
        }
        text += "END\n"
        return text
    }


    /// Whether a rectangle touches the region at all: any ring vertex inside it, any of its
    /// corners inside a ring, or any ring segment crossing one of its edges. The degree-cell
    /// filter for elevation, so it errs towards keeping and ignores subtract-rings.
    static func rectTouches(_ rings: [Ring],
                            minLon: Double, minLat: Double,
                            maxLon: Double, maxLat: Double) -> Bool {
        func inRect(_ p: (lon: Double, lat: Double)) -> Bool {
            p.lon >= minLon && p.lon <= maxLon && p.lat >= minLat && p.lat <= maxLat
        }
        func inRing(_ ring: Ring, _ lon: Double, _ lat: Double) -> Bool {
            var inside = false
            var j = ring.points.count - 1
            for i in 0..<ring.points.count {
                let a = ring.points[i], b = ring.points[j]
                if (a.lat > lat) != (b.lat > lat),
                   lon < (b.lon - a.lon) * (lat - a.lat) / (b.lat - a.lat) + a.lon {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
        // A long border segment can slice a corner of the cell without either endpoint
        // being inside it, so edges are tested for crossings too.
        func crosses(_ a: (lon: Double, lat: Double), _ b: (lon: Double, lat: Double)) -> Bool {
            func side(_ px: Double, _ py: Double,
                      _ qx: Double, _ qy: Double, _ rx: Double, _ ry: Double) -> Double {
                (qx - px) * (ry - py) - (qy - py) * (rx - px)
            }
            let corners = [(minLon, minLat), (maxLon, minLat), (maxLon, maxLat), (minLon, maxLat)]
            for i in 0..<4 {
                let c = corners[i], d = corners[(i + 1) % 4]
                let d1 = side(a.lon, a.lat, b.lon, b.lat, c.0, c.1)
                let d2 = side(a.lon, a.lat, b.lon, b.lat, d.0, d.1)
                let d3 = side(c.0, c.1, d.0, d.1, a.lon, a.lat)
                let d4 = side(c.0, c.1, d.0, d.1, b.lon, b.lat)
                if d1 * d2 < 0 && d3 * d4 < 0 { return true }
            }
            return false
        }
        for ring in rings where !ring.subtract {
            if ring.points.contains(where: inRect) { return true }
            if inRing(ring, minLon, minLat) || inRing(ring, maxLon, minLat)
                || inRing(ring, maxLon, maxLat) || inRing(ring, minLon, maxLat) {
                return true
            }
            var j = ring.points.count - 1
            for i in 0..<ring.points.count {
                if crosses(ring.points[i], ring.points[j]) { return true }
                j = i
            }
        }
        return false
    }
}

struct GroundMask {
    /// About 550 m of cell at the equator: fine enough that the cut follows the border,
    /// coarse enough that a country is a few megabits.
    private static let preferredCell = 0.005
    /// The ceiling on the table. A build spanning a continent coarsens its cells to fit
    /// rather than asking for a gigabyte of mask.
    private static let mostCells = 16_000_000
    /// How far past the outline the mask reaches, in degrees.
    static let margin = 0.05

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
        guard pts.count >= 3 else { return }
        for row in 0..<rows {
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
            var row = 0
            while row < rows {
                if out[row * columns + column] {
                    for d in max(0, row - reach)...min(rows - 1, row + reach) {
                        bits[d * columns + column] = true
                    }
                }
                row += 1
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
                    if run.count >= 2 {
                        out.append(Contours.Line(elevation: line.elevation,
                                                 points: run, closed: false))
                    }
                    run.removeAll(keepingCapacity: true)
                }
            }
            if run.count >= 2 {
                out.append(Contours.Line(elevation: line.elevation, points: run,
                                         closed: line.closed && !cut))
            }
        }
        return out
    }
}
