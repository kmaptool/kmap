import Foundation

/// One downloadable extract from Geofabrik's index.
struct Region {
    let id: String
    let name: String
    let parentID: String?
    let pbfURL: URL?
    /// The box around everything the region touches.
    let bbox: BBox
    /// The ground actually covered: one box per ring of the outline, so a region reaching
    /// across 180 deg yields two distant boxes rather than one spanning the globe. Anything
    /// counting ground -- elevation cells, the size estimate -- reads these.
    let boxes: [BBox]
    /// The outline itself, one ring of [lon, lat] vertices per entry in `boxes`. Boxes
    /// answer roughly where the region lies; the rings answer whether a given point is
    /// inside it.
    var rings: [[(lon: Double, lat: Double)]] = []
    var childIDs: [String] = []

    var hasChildren: Bool { !childIDs.isEmpty }

    /// Rough count of 1 deg x 1 deg DEM tiles the region covers.
    var demTileCount: Int { boxes.reduce(0) { $0 + $1.demTileCount } }

    /// The slash-separated region path, used for cache filenames and output naming.
    var slug: String { id }

    /// The URL of the sibling `.md5` checksum file Geofabrik publishes.
    var md5URL: URL? {
        guard let pbfURL else { return nil }
        return URL(string: pbfURL.absoluteString + ".md5")
    }

    /// Whether the point lies inside the region's outline: even-odd ray casting over every
    /// ring, so an enclave ring subtracts itself. A region whose outline never parsed falls
    /// back to its boxes; a ring whose box misses the point cannot change parity, and is skipped.
    func holds(lat: Double, lon: Double) -> Bool {
        guard !rings.isEmpty else {
            return boxes.isEmpty
                ? bbox.contains(lat: lat, lon: lon) : boxes.contains { $0.contains(lat: lat, lon: lon) }
        }
        var inside = false
        for at in rings.indices where rings[at].count >= 3 {
            if at < boxes.count, !boxes[at].contains(lat: lat, lon: lon) { continue }
            if Self.ring(rings[at], holds: lat, lon) { inside.toggle() }
        }
        return inside
    }

    /// Whether the whole box lies inside the outline, or outside it; nil where the outline
    /// runs through the box, or may: a side of it whose own box meets the box.
    func holdsWhole(_ box: BBox) -> Bool? {
        guard !rings.isEmpty else { return nil }
        for at in rings.indices where rings[at].count >= 3 {
            if at < boxes.count, !boxes[at].intersects(box) { continue }
            let ring = rings[at]
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[i], b = ring[j]
                if max(a.lon, b.lon) >= box.minLon, min(a.lon, b.lon) <= box.maxLon,
                    max(a.lat, b.lat) >= box.minLat, min(a.lat, b.lat) <= box.maxLat
                {
                    return nil
                }
                j = i
            }
        }
        return holds(lat: (box.minLat + box.maxLat) / 2, lon: (box.minLon + box.maxLon) / 2)
    }

    private static func ring(_ ring: [(lon: Double, lat: Double)], holds lat: Double, _ lon: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.lat > lat) != (b.lat > lat),
                lon < (b.lon - a.lon) * (lat - a.lat) / (b.lat - a.lat) + a.lon
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Whether the point sits on the ring itself, where a ray cannot tell in from out.
    private static func ring(_ ring: [(lon: Double, lat: Double)], passes lat: Double, _ lon: Double) -> Bool {
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (b.lon - a.lon) * (lat - a.lat) == (b.lat - a.lat) * (lon - a.lon),
                lat >= min(a.lat, b.lat), lat <= max(a.lat, b.lat), lon >= min(a.lon, b.lon), lon <= max(a.lon, b.lon)
            {
                return true
            }
            j = i
        }
        return false
    }

    /// Whether `ring` lies inside `other`. Rings of an outline do not cross, so any point
    /// of the one that is off the other answers for all of it: a vertex, or failing those
    /// the middle of a side.
    private static func ring(_ ring: [(lon: Double, lat: Double)], isInside other: [(lon: Double, lat: Double)]) -> Bool
    {
        if let off = ring.first(where: { !Self.ring(other, passes: $0.lat, $0.lon) }) {
            return Self.ring(other, holds: off.lat, off.lon)
        }
        var j = ring.count - 1
        for i in 0..<ring.count {
            let middle = (lon: (ring[i].lon + ring[j].lon) / 2, lat: (ring[i].lat + ring[j].lat) / 2)
            if !Self.ring(other, passes: middle.lat, middle.lon) {
                return Self.ring(other, holds: middle.lat, middle.lon)
            }
            j = i
        }
        return false
    }

    /// The ground the outline holds, as `holds` reads it: a ring inside another is taken
    /// away. On an equal-area projection, in units comparable between regions only.
    var outlineArea: Double {
        func sine(_ degrees: Double) -> Double { sin(degrees * .pi / 180) }
        guard !rings.isEmpty else {
            return (boxes.isEmpty ? [bbox] : boxes).reduce(0.0) {
                $0 + ($1.isValid ? ($1.maxLon - $1.minLon) * (sine($1.maxLat) - sine($1.minLat)) : 0)
            }
        }
        var area = 0.0
        for (at, ring) in rings.enumerated() where ring.count >= 3 {
            var twice = 0.0
            var j = ring.count - 1
            for i in 0..<ring.count {
                twice += (ring[i].lon - ring[j].lon) * (sine(ring[i].lat) + sine(ring[j].lat))
                j = i
            }
            let around = rings.indices.filter {
                $0 != at && rings[$0].count >= 3 && Self.ring(ring, isInside: rings[$0])
            }
            area += around.count.isMultiple(of: 2) ? abs(twice) / 2 : -abs(twice) / 2
        }
        return area
    }
}
