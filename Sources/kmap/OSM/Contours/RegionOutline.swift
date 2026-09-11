import Foundation

/// The ground a region actually is, and the contours that belong on it. Tiles are
/// rectangles and elevation is fetched by the degree, so a build would otherwise carry
/// relief over ground no chosen region provides data for. Geofabrik publishes each
/// extract's cutting polygon as a `.poly` file, and the contours are cut to that outline.
enum RegionOutline {
    /// A ring is a polygon: fewer points is a line, and dropped.
    static let fewestRingPoints = 3

    /// One ring of a `.poly` file. Osmosis marks a ring to subtract, a hole, by
    /// prefixing its name with `!`.
    struct Ring {
        var subtract: Bool
        var points: [(lon: Double, lat: Double)]
    }

    /// Parses the osmosis `.poly` format: a file-name line, then per ring a name line,
    /// coordinate pairs and END, with a final END closing the file.
    /// - Returns: nil unless at least one additive ring was read.
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
                    if ring.points.count >= fewestRingPoints { rings.append(ring) }
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
}
