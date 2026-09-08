import Foundation

/// Whether a built map's tiles cover the ground they claim, or leave holes in it. A tile
/// states its bounds in its TRE header and carries the sea fill and the DEM, so a point
/// inside the map's box that falls in no tile draws blank. The box sampled is the one
/// around the tiles themselves, so the fringe of a non-rectangular region is not a hole.
enum MapCoverage {
    struct Tile {
        let name: String
        let minLat: Double, minLon: Double
        let maxLat: Double, maxLon: Double

        func holds(lat: Double, lon: Double) -> Bool {
            lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }
    }

    struct Report {
        var tiles: [Tile]
        var minLat: Double, minLon: Double
        var maxLat: Double, maxLon: Double
        var sampled: Int
        var holes: [(lat: Double, lon: Double)]
    }

    /// Garmin's 24-bit angle: a full circle divided into 2^24.
    static func degrees(_ raw: Int32) -> Double {
        Double(raw) * 360 / Double(1 << 24)
    }

    /// A signed 24-bit little-endian value.
    static func signed24(_ bytes: [UInt8], at offset: Int) -> Int32? {
        guard offset + 2 < bytes.count else { return nil }
        let value = Int32(bytes[offset]) | Int32(bytes[offset + 1]) << 8
            | Int32(bytes[offset + 2]) << 16
        return value & 0x80_0000 != 0 ? value - (1 << 24) : value
    }

    /// The bounds a TRE header states, or nil where this is not a TRE.
    ///
    /// The header opens with its own length and the words `GARMIN TRE`; the four corners
    /// sit at 0x15 in the order north, east, south, west.
    static func bounds(ofTRE header: [UInt8])
        -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)? {
        guard header.count >= 0x21 else { return nil }
        let name = String(decoding: header[2..<12], as: UTF8.self)
        guard name == "GARMIN TRE" else { return nil }
        guard let maxLat = signed24(header, at: 0x15),
              let maxLon = signed24(header, at: 0x18),
              let minLat = signed24(header, at: 0x1B),
              let minLon = signed24(header, at: 0x1E) else { return nil }
        return (degrees(minLat), degrees(minLon), degrees(maxLat), degrees(maxLon))
    }

    /// Every map tile in a container, with the ground it claims.
    static func tiles(in url: URL) -> [Tile] {
        var out: [Tile] = []
        for file in ImgContainer.directory(of: url) where file.ext.uppercased() == "TRE" {
            // The header states its own length in its first two bytes; two is enough to
            // learn how much to read.
            guard let opening = ImgContainer.read(file, from: url, offset: 0, length: 2),
                  opening.count >= 2 else { continue }
            let length = Int(opening[0]) | Int(opening[1]) << 8
            guard length >= 0x21,
                  let header = ImgContainer.read(file, from: url, offset: 0, length: length),
                  let box = bounds(ofTRE: [UInt8](header)) else { continue }
            out.append(Tile(name: file.name, minLat: box.minLat, minLon: box.minLon,
                            maxLat: box.maxLat, maxLon: box.maxLon))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Samples the box around the tiles and reports every point no tile holds.
    ///
    /// The grid is offset by half a step so a sample never lands exactly on a shared
    /// edge, where both neighbours claim it and a gap of nothing would read as covered.
    static func check(_ tiles: [Tile], step: Double = 0.25) -> Report? {
        guard step > 0,
              let minLat = tiles.map(\.minLat).min(),
              let minLon = tiles.map(\.minLon).min(),
              let maxLat = tiles.map(\.maxLat).max(),
              let maxLon = tiles.map(\.maxLon).max() else { return nil }

        var sampled = 0
        var holes: [(lat: Double, lon: Double)] = []
        var lat = minLat + step / 2
        while lat < maxLat {
            var lon = minLon + step / 2
            while lon < maxLon {
                sampled += 1
                if !tiles.contains(where: { $0.holds(lat: lat, lon: lon) }) {
                    holes.append((lat, lon))
                }
                lon += step
            }
            lat += step
        }
        return Report(tiles: tiles, minLat: minLat, minLon: minLon,
                      maxLat: maxLat, maxLon: maxLon, sampled: sampled, holes: holes)
    }
}
