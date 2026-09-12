import Foundation

/// The ground, read straight off the .hgt tiles the contour step already downloaded.
///
/// The posts are 30 m apart while the gaps this is asked about are metres, so it serves
/// only as a backstop against a drop big enough to swallow a path; the tags decide the rest.
final class Terrain {
    private let directory: URL
    private let size = 3601
    /// SRTM marks a void with -32768; nothing that low is a reading.
    private static let voidBelow: Int16 = -32000
    /// One arc second along a meridian, in metres.
    private static let metresPerPost = 30.9
    private var tiles: [Int32: Data?] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func elevation(_ lat: Double, _ lon: Double) -> Double? {
        // Tiles share their edges, so a point exactly on a degree line belongs to either.
        // The northern tile is asked first; the one below answers when it is absent.
        let south = Int(lat.rounded(.down)), west = Int(lon.rounded(.down))
        for southEdge in [south, lat == Double(south) ? south - 1 : south] {
            for westEdge in [west, lon == Double(west) ? west - 1 : west] {
                if let found = read(lat, lon, southEdge, westEdge) { return found }
            }
        }
        return nil
    }

    private func read(_ lat: Double, _ lon: Double, _ south: Int, _ west: Int) -> Double? {
        guard let data = tile(south, west) else { return nil }
        let row = max(0, min(size - 1, Int(((Double(south) + 1 - lat) * Double(size - 1)).rounded())))
        let column = max(0, min(size - 1, Int(((lon - Double(west)) * Double(size - 1)).rounded())))
        let at = (row * size + column) * 2
        guard at + 1 < data.count else { return nil }
        let value = Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1]))
        return value <= Terrain.voidBelow ? nil : Double(value)
    }

    /// Steepest gradient in degrees across the cells around the point.
    func slope(_ lat: Double, _ lon: Double) -> Double? {
        guard let here = elevation(lat, lon) else { return nil }
        let step = 1.0 / Double(size - 1)
        let span = Terrain.metresPerPost
        let east = span * cos(lat * .pi / 180)
        var worst = 0.0
        for (dlat, dlon, run) in [(step, 0.0, span), (-step, 0.0, span),
                                  (0.0, step, east), (0.0, -step, east)] {
            if let other = elevation(lat + dlat, lon + dlon), run > 0 {
                worst = max(worst, abs(other - here) / run)
            }
        }
        return atan(worst) * 180 / .pi
    }

    private func tile(_ south: Int, _ west: Int) -> Data? {
        let key = Int32(south * 1000 + west)
        if let cached = tiles[key] { return cached }
        let name = HGTName.of(lat: south, lon: west) + ".hgt"
        let url = directory.appendingPathComponent(name)
        let data = try? Data(contentsOf: url, options: .alwaysMapped)
        tiles[key] = data
        return data
    }
}
