import Foundation

/// The ground, read straight off the .hgt tiles of the build's elevation sources.
///
/// The posts are 30 m apart while the gaps this is asked about are metres, so it serves
/// only as a backstop against a drop big enough to swallow a path; the tags decide the rest.
final class Terrain {
    /// Asked in order: a tile is read from the first directory holding it.
    private let directories: [URL]
    /// Posts along a tile's side: 3601 at 1 arc-second, 1201 at 3. A tile is read by the
    /// grid its length names.
    private static let sides = [3601, 1201]
    /// SRTM marks a void with -32768; nothing that low is a reading.
    private static let voidBelow: Int16 = -32000
    /// 1 arc-second along a meridian, in metres.
    private static let metresPerArcSecond = 30.9
    private static let arcSecondsPerDegree = 3600

    private struct Tile {
        let data: Data
        let side: Int
    }

    private var tiles: [Int32: Tile?] = [:]

    init(directories: [URL]) {
        self.directories = directories
    }

    convenience init(directory: URL) {
        self.init(directories: [directory])
    }

    /// The ground at the point, between its 4 posts: the nearest post alone would read a
    /// slope as a step wherever a gap straddles the halfway line between 2 posts.
    func elevation(_ lat: Double, _ lon: Double) -> Double? {
        let south = Int(lat.rounded(.down)), west = Int(lon.rounded(.down))
        for southEdge in [south, lat == Double(south) ? south - 1 : south] {
            for westEdge in [west, lon == Double(west) ? west - 1 : west] {
                if let found = between(lat, lon, southEdge, westEdge) { return found }
            }
        }
        return nil
    }

    private func between(_ lat: Double, _ lon: Double, _ south: Int, _ west: Int) -> Double? {
        guard let tile = tile(south, west) else { return nil }
        let size = tile.side, data = tile.data
        let y = max(0, min(Double(size - 1), (Double(south) + 1 - lat) * Double(size - 1)))
        let x = max(0, min(Double(size - 1), (lon - Double(west)) * Double(size - 1)))
        let row = min(size - 2, Int(y)), column = min(size - 2, Int(x))
        let fy = y - Double(row), fx = x - Double(column)
        func value(_ r: Int, _ c: Int) -> Double? {
            let at = (r * size + c) * 2
            guard at + 1 < data.count else { return nil }
            let raw = Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1]))
            return raw <= Terrain.voidBelow ? nil : Double(raw)
        }
        // Only the posts that weigh anything are asked for: a point on a post is that
        // post, and a tile cut short still answers for the posts it holds.
        var sum = 0.0
        for (r, c, weight) in [
            (row, column, (1 - fx) * (1 - fy)), (row, column + 1, fx * (1 - fy)),
            (row + 1, column, (1 - fx) * fy), (row + 1, column + 1, fx * fy)
        ] where weight > 0 {
            guard let height = value(r, c) else { return nil }
            sum += height * weight
        }
        return sum
    }

    /// The reading nearest the point, and the side of the tile it came from.
    private func post(_ lat: Double, _ lon: Double) -> (height: Double, side: Int)? {
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

    private func read(_ lat: Double, _ lon: Double, _ south: Int, _ west: Int) -> (height: Double, side: Int)? {
        guard let tile = tile(south, west) else { return nil }
        let size = tile.side, data = tile.data
        let row = max(0, min(size - 1, Int(((Double(south) + 1 - lat) * Double(size - 1)).rounded())))
        let column = max(0, min(size - 1, Int(((lon - Double(west)) * Double(size - 1)).rounded())))
        let at = (row * size + column) * 2
        guard at + 1 < data.count else { return nil }
        let value = Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1]))
        return value <= Terrain.voidBelow ? nil : (Double(value), size)
    }

    /// Steepest gradient in degrees around the point, a post of the tile's own grid away.
    func slope(_ lat: Double, _ lon: Double) -> Double? {
        guard let (_, side) = post(lat, lon), let here = elevation(lat, lon) else { return nil }
        let step = 1.0 / Double(side - 1)
        // Arc-seconds per post: 1 or 3.
        let span = Terrain.metresPerArcSecond * Double(Terrain.arcSecondsPerDegree / (side - 1))
        let east = span * cos(lat * .pi / 180)
        var worst = 0.0
        for (dlat, dlon, run) in [
            (step, 0.0, span), (-step, 0.0, span),
            (0.0, step, east), (0.0, -step, east)
        ] {
            if let other = elevation(lat + dlat, lon + dlon), run > 0 {
                worst = max(worst, abs(other - here) / run)
            }
        }
        return atan(worst) * 180 / .pi
    }

    /// The tile from the first directory holding it. A file of neither length is a 1
    /// arc-second tile cut short and answers for the posts it holds.
    private func tile(_ south: Int, _ west: Int) -> Tile? {
        let key = Int32(south * 1000 + west)
        if let cached = tiles[key] { return cached }
        let name = HGTName.of(lat: south, lon: west) + ".hgt"
        let found = directories.lazy.compactMap { directory -> Tile? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name), options: .alwaysMapped)
            else { return nil }
            let side = Terrain.sides.first { data.count == $0 * $0 * 2 } ?? Terrain.sides[0]
            return Tile(data: data, side: side)
        }.first
        tiles[key] = found
        return found
    }
}
