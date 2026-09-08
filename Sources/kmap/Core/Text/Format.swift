import Foundation

enum Fmt {
    /// Formats a byte count in decimal units: "1.4 GB", "812 MB", "43 kB", "7 B".
    static func bytes(_ n: Int64) -> String {
        let v = Double(n)
        switch v {
        case ..<1_000: return "\(n) B"
        case ..<1_000_000: return String(format: "%.0f kB", v / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f MB", v / 1_000_000)
        default: return String(format: "%.2f GB", v / 1_000_000_000)
        }
    }

    /// Formats memory use as "12.4/64 GB". Both halves are in binary gigabytes and share
    /// one unit, which `Fmt.bytes` would not guarantee.
    static func memory(used: UInt64, total: UInt64) -> String {
        let gigabyte = 1_073_741_824.0
        let usedGB = Double(used) / gigabyte
        let totalGB = Double(total) / gigabyte
        return String(format: "%.1f/%.0f ", usedGB, totalGB) + t("GB")
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// Formats a duration as "48s", "4m 12s" or "1h 03m"; "—" beyond 48 hours.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 60 * 60 * 48 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "  0%" }
        return String(format: "%3.0f%%", max(0, min(1, fraction)) * 100)
    }

    /// Formats degrees with a compass suffix.
    static func coord(_ value: Double, lat: Bool) -> String {
        let suffix = lat ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W")
        return String(format: "%.2f°%@", abs(value), suffix)
    }

    static func timestamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = LocalTime.zone
        return df.string(from: date)
    }

    static func clock(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        df.timeZone = LocalTime.zone
        return df.string(from: date)
    }
}

/// A geographic bounding box in degrees.
struct BBox: Codable, Equatable {
    var minLon: Double
    var minLat: Double
    var maxLon: Double
    var maxLat: Double

    static let empty = BBox(minLon: .infinity, minLat: .infinity,
                            maxLon: -.infinity, maxLat: -.infinity)

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
        BBox(minLon: (minLon - margin).rounded(.down),
             minLat: (minLat - margin).rounded(.down),
             maxLon: (maxLon + margin).rounded(.up),
             maxLat: (maxLat + margin).rounded(.up))
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
        let box = BBox(minLon: Swift.max(minLon, other.minLon),
                       minLat: Swift.max(minLat, other.minLat),
                       maxLon: Swift.min(maxLon, other.maxLon),
                       maxLat: Swift.min(maxLat, other.maxLat))
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
