import Foundation

/// Reads a compiled map's elements from the TRE/RGN pairs inside a Garmin `.img`.
///
/// Every tile, the most detailed level of each, and in it the polylines, polygons and
/// points - classic and extended types alike - in the file's own 24-bit map units.
enum ImgElements {
    struct Coord {
        let lat: Int32
        let lon: Int32
    }

    /// A rectangle of map units the caller is interested in, cut to a region's outline
    /// where it has one. Elements entirely outside every ground are skipped, and
    /// subdivisions nowhere near one are not even read.
    struct Ground {
        let minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32
        /// The region whose extract the ground is, where it is known: a header's box
        /// holds ground the extract has no data on.
        let outline: kmap.Region?

        private static let degrees = 360 / Double(1 << 24)
        /// A full turn of longitude, in map units.
        static let turn = Int32(1 << 24)

        /// From degrees, with one map unit of slack either side, so a vertex sitting
        /// exactly on the edge is kept.
        init(_ box: BBox, outline: kmap.Region? = nil) {
            let units = Double(1 << 24) / 360.0
            minLat = Int32((box.minLat * units).rounded(.down)) - 1
            minLon = Int32((box.minLon * units).rounded(.down)) - 1
            maxLat = Int32((box.maxLat * units).rounded(.up)) + 1
            maxLon = Int32((box.maxLon * units).rounded(.up)) + 1
            self.outline = outline
        }

        func contains(_ c: Coord) -> Bool {
            if holds(lat: c.lat, lon: c.lon) { return true }
            // An element east of 180 deg runs on past the end of the scale.
            let half = Self.turn / 2
            if c.lon >= half { return holds(lat: c.lat, lon: c.lon - Self.turn) }
            if c.lon <= -half { return holds(lat: c.lat, lon: c.lon + Self.turn) }
            return false
        }

        private func holds(lat: Int32, lon: Int32) -> Bool {
            guard lat >= minLat, lat <= maxLat, lon >= minLon, lon <= maxLon else { return false }
            guard let outline else { return true }
            return outline.holds(lat: Double(lat) * Self.degrees, lon: Double(lon) * Self.degrees)
        }

        /// What the outline says of a whole subdivision: all of it on the ground, none of
        /// it, or nil where each element is to be asked, as on a ground with no outline.
        /// One across 180 deg is asked side by side.
        func holds(_ division: Subdivision) -> Bool? {
            guard let outline else { return nil }
            let sides = division.box.sidesOf180.map { outline.holdsWhole($0) }
            if sides.allSatisfy({ $0 == true }) { return true }
            return sides.allSatisfy({ $0 == false }) ? false : nil
        }
    }

    /// How the grounds stand to a subdivision: `whole` where one of them holds all of it,
    /// and the grounds an element of it may lie on.
    static func reach(of division: Subdivision, on grounds: [Ground]) -> (whole: Bool, asked: [Ground]) {
        var asked: [Ground] = []
        for ground in grounds {
            switch ground.holds(division) {
            case true?: return (true, [])
            case false?: continue
            case nil: asked.append(ground)
            }
        }
        return (false, asked)
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case noTiles
        case cutShort
        case malformed(String, String)
        var description: String {
            switch self {
            case .noTiles: return "no map tiles found — is this a Garmin .img?"
            case .cutShort: return "the map is cut short — its last files end past the end of it; download it again"
            case .malformed(let tile, let what): return "\(tile): \(what)"
            }
        }
    }

    /// Walks the map and hands every element of the detail level to `emit`, in file order:
    /// tile by tile, subdivision by subdivision, lines then polygons then points within each.
    ///
    /// - Parameters:
    ///   - extendedAreasAndPoints: whether polygons and points of the extended types
    ///     (0x10000 and up) are read. Lines of extended types are always read.
    ///   - tick: called once per element read, for progress.
    ///   - tile: called once per tile, before it is read: where cancellation is asked
    ///     when no element of a tile lies near the ground.
    /// - Parameter resolution: read only the subdivisions drawn at this resolution,
    ///   whatever level or tile they live in: to compare 2 maps that ladder their zooms
    ///   differently, or to ask what one draws at a given zoom.
    static func read(
        img: URL,
        grounds: [Ground],
        extendedAreasAndPoints: Bool,
        coarserLevels: Bool = false,
        resolution: Int? = nil,
        tick: () throws -> Void,
        tile: () throws -> Void = {},
        emit: (ElementDumper.Kind, Int, [Coord]) -> Void
    ) throws {
        try read(
            img: img,
            grounds: grounds,
            extendedAreasAndPoints: extendedAreasAndPoints,
            coarserLevels: coarserLevels,
            resolution: resolution,
            tick: tick,
            tile: tile
        ) {
            kind,
            type,
            coords,
            _ in emit(kind, type, coords)
        }
    }

    /// The same walk, telling the caller which resolution each element is drawn at: a
    /// style may keep a second, thinner vocabulary for the zoomed-out levels, and only
    /// the resolution tells the two apart.
    static func read(
        img: URL,
        grounds: [Ground],
        extendedAreasAndPoints: Bool,
        coarserLevels: Bool = false,
        resolution: Int? = nil,
        tick: () throws -> Void,
        tile: () throws -> Void = {},
        emit: (ElementDumper.Kind, Int, [Coord], Int) -> Void
    ) throws {
        let directory = ImgContainer.directory(of: img)
        let tiles = directory.filter { $0.ext.uppercased() == "TRE" }
        guard !tiles.isEmpty else { throw Trouble.noTiles }
        // Read in part, a map would be taken for a smaller one: a style recovered from what
        // it draws, a count of what it holds.
        guard ImgContainer.isWhole(img, headers: false) else { throw Trouble.cutShort }
        for tre in tiles {
            guard
                let rgn = directory.first(where: {
                    $0.name == tre.name && $0.ext.uppercased() == "RGN"
                })
            else { continue }
            try tile()
            guard let treData = ImgContainer.read(tre, from: img) else { continue }
            let tree = try Tree(treData, tile: tre.name)
            // Level 0 is the most detailed; it is named by that number, not by its
            // position in the list. `coarserLevels` reads everything above it instead:
            // the zoomed-out drawings, where a style may keep what it never draws up
            // close - a reserve's hatch over half a district.
            let divisions = tree.subdivisions.compactMap { division -> (Subdivision, whole: Bool, asked: [Ground])? in
                guard
                    resolution.map({ 24 - division.shift == $0 })
                        ?? (coarserLevels ? division.level > 0 : division.level == 0),
                    grounds.contains(where: { division.near($0) })
                else { return nil }
                // A subdivision an outline leaves out whole is not read either.
                let reach = reach(of: division, on: grounds)
                return reach.whole || !reach.asked.isEmpty ? (division, reach.whole, reach.asked) : nil
            }
            // The drawing is read only for a tile with something near the ground: a whole
            // device map is gigabytes, often read off a card.
            guard !divisions.isEmpty, let rgnData = ImgContainer.read(rgn, from: img) else { continue }
            let region = try Region(rgnData, tile: tre.name)
            for (division, whole, asked) in divisions {
                try region.read(
                    division,
                    extendedAreasAndPoints: extendedAreasAndPoints,
                    tile: tre.name
                ) { kind, type, coords in
                    try tick()
                    guard whole || coords.contains(where: { c in asked.contains { $0.contains(c) } })
                    else { return }
                    emit(kind, type, broughtRound(coords), 24 - division.shift)
                }
            }
        }
    }

    /// An element drawn wholly past 180 deg, as a tile across it draws, handed over with
    /// its longitudes back on the scale, where the ground has it. One drawn across 180 deg
    /// stays as it is, a whole shape.
    static func broughtRound(_ coords: [Coord]) -> [Coord] {
        let half = Ground.turn / 2
        guard let first = coords.first, first.lon >= half || first.lon <= -half else { return coords }
        let east = first.lon > 0
        guard coords.allSatisfy({ east ? $0.lon >= half : $0.lon <= -half }),
            coords.contains(where: { east ? $0.lon > half : $0.lon < -half })
        else { return coords }
        return coords.map { Coord(lat: $0.lat, lon: east ? $0.lon - Ground.turn : $0.lon + Ground.turn) }
    }
}
