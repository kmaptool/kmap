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
            return (boxes.isEmpty ? [bbox] : boxes)
                .contains { $0.contains(lat: lat, lon: lon) }
        }
        var inside = false
        for (at, ring) in rings.enumerated() where ring.count >= 3 {
            if at < boxes.count, !boxes[at].contains(lat: lat, lon: lon) { continue }
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
        }
        return inside
    }
}
