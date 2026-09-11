import Foundation

/// Whether ground meets an outline, for choosing the degree cells elevation is fetched for.
extension RegionOutline {
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
        let corners = [(minLon, minLat), (maxLon, minLat), (maxLon, maxLat), (minLon, maxLat)]
        func crosses(_ a: (lon: Double, lat: Double), _ b: (lon: Double, lat: Double)) -> Bool {
            func side(_ px: Double, _ py: Double,
                      _ qx: Double, _ qy: Double, _ rx: Double, _ ry: Double) -> Double {
                (qx - px) * (ry - py) - (qy - py) * (rx - px)
            }
            for i in 0..<corners.count {
                let c = corners[i], d = corners[(i + 1) % corners.count]
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
