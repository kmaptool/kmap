import Foundation

/// A geographic bounding box in degrees.
struct BBox: Codable, Equatable {
    var minLon: Double
    var minLat: Double
    var maxLon: Double
    var maxLat: Double

    static let empty = BBox(
        minLon: .infinity,
        minLat: .infinity,
        maxLon: -.infinity,
        maxLat: -.infinity
    )

    var isValid: Bool { minLon <= maxLon && minLat <= maxLat && minLon.isFinite && maxLat.isFinite }

    mutating func extend(lon: Double, lat: Double) {
        minLon = Swift.min(minLon, lon)
        maxLon = Swift.max(maxLon, lon)
        minLat = Swift.min(minLat, lat)
        maxLat = Swift.max(maxLat, lat)
    }

    /// Returns the box grown by `margin` and snapped outwards to whole degrees, as DEM
    /// tile fetching requires.
    func snappedOutward(margin: Double = 0.0) -> BBox {
        BBox(
            minLon: (minLon - margin).rounded(.down),
            minLat: (minLat - margin).rounded(.down),
            maxLon: (maxLon + margin).rounded(.up),
            maxLat: (maxLat + margin).rounded(.up)
        )
    }

    /// pyhgtmap's `--area` format: minlon:minlat:maxlon:maxlat.
    var areaArgument: String {
        String(format: "%.4f:%.4f:%.4f:%.4f", minLon, minLat, maxLon, maxLat)
    }

    var display: String {
        guard isValid else { return "—" }
        return "\(Fmt.coord(minLat, lat: true)) \(Fmt.coord(minLon, lat: false))  →  "
            + "\(Fmt.coord(maxLat, lat: true)) \(Fmt.coord(maxLon, lat: false))"
    }

    func contains(lat: Double, lon: Double) -> Bool {
        lon >= minLon && lon <= maxLon && lat >= minLat && lat <= maxLat
    }

    func contains(_ other: BBox) -> Bool {
        other.minLon >= minLon && other.maxLon <= maxLon
            && other.minLat >= minLat && other.maxLat <= maxLat
    }

    func intersects(_ other: BBox) -> Bool {
        minLon <= other.maxLon && maxLon >= other.minLon
            && minLat <= other.maxLat && maxLat >= other.minLat
    }

    /// Area in square degrees. Comparable between boxes only; not a ground area.
    var squareDegrees: Double {
        guard isValid else { return 0 }
        return (maxLon - minLon) * (maxLat - minLat)
    }

    /// The overlap of the two boxes, `.empty` where they only touch or miss.
    func intersection(_ other: BBox) -> BBox {
        let box = BBox(
            minLon: Swift.max(minLon, other.minLon),
            minLat: Swift.max(minLat, other.minLat),
            maxLon: Swift.min(maxLon, other.maxLon),
            maxLat: Swift.min(maxLat, other.maxLat)
        )
        return box.isValid ? box : .empty
    }

    /// Degrees from the point to the nearest edge, zero inside. Uncorrected for the
    /// latitude squeeze, so it is comparable only with another such distance.
    func distance(toLat lat: Double, lon: Double) -> Double {
        let dx = Swift.max(0, Swift.max(minLon - lon, lon - maxLon))
        let dy = Swift.max(0, Swift.max(minLat - lat, lat - maxLat))
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Count of 1°×1° DEM tiles the box covers, as a proxy for contour cost.
    var demTileCount: Int {
        guard isValid else { return 0 }
        let s = snappedOutward()
        return max(0, Int(s.maxLon - s.minLon)) * max(0, Int(s.maxLat - s.minLat))
    }
}
