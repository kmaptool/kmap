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

    /// A rectangle of map units the caller is interested in. Elements entirely outside
    /// every ground are skipped, and subdivisions nowhere near one are not even read.
    struct Ground {
        let minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32

        /// From degrees, with one map unit of slack either side, so a vertex sitting
        /// exactly on the edge is kept.
        init(_ box: BBox) {
            let units = Double(1 << 24) / 360.0
            minLat = Int32((box.minLat * units).rounded(.down)) - 1
            minLon = Int32((box.minLon * units).rounded(.down)) - 1
            maxLat = Int32((box.maxLat * units).rounded(.up)) + 1
            maxLon = Int32((box.maxLon * units).rounded(.up)) + 1
        }

        func contains(_ c: Coord) -> Bool {
            c.lat >= minLat && c.lat <= maxLat && c.lon >= minLon && c.lon <= maxLon
        }
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case noTiles
        case malformed(String, String)
        var description: String {
            switch self {
            case .noTiles: return "no map tiles found — is this a Garmin .img?"
            case .malformed(let tile, let what): return "\(tile): \(what)"
            }
        }
    }

    /// Walks the map and hands every element of the detail level to `emit`, in the
    /// order the file has them: tile by tile, subdivision by subdivision, lines then
    /// polygons then points within each.
    ///
    /// - Parameters:
    ///   - extendedAreasAndPoints: whether polygons and points of the extended types
    ///     (0x10000 and up) are read. Lines of extended types are always read.
    ///   - tick: called once per element read, for progress.
    /// - Parameter resolution: read only the subdivisions drawn at this resolution,
    ///   whatever level or tile they live in - the way to compare two maps that ladder
    ///   their zooms differently, or to ask what one draws at a given zoom.
    static func read(
        img: URL,
        grounds: [Ground],
        extendedAreasAndPoints: Bool,
        coarserLevels: Bool = false,
        resolution: Int? = nil,
        tick: () throws -> Void,
        emit: (ElementDumper.Kind, Int, [Coord]) -> Void
    ) throws {
        try read(
            img: img,
            grounds: grounds,
            extendedAreasAndPoints: extendedAreasAndPoints,
            coarserLevels: coarserLevels,
            resolution: resolution,
            tick: tick
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
        emit: (ElementDumper.Kind, Int, [Coord], Int) -> Void
    ) throws {
        let directory = ImgContainer.directory(of: img)
        let tiles = directory.filter { $0.ext.uppercased() == "TRE" }
        guard !tiles.isEmpty else { throw Trouble.noTiles }
        for tre in tiles {
            guard
                let rgn = directory.first(where: {
                    $0.name == tre.name && $0.ext.uppercased() == "RGN"
                })
            else { continue }
            // Asked once a tile too: a tile far from the ground emits nothing to ask on.
            try tick()
            guard let treData = ImgContainer.read(tre, from: img) else { continue }
            let tree = try Tree(treData, tile: tre.name)
            // Level 0 is the most detailed; it is named by that number, not by its
            // position in the list. `coarserLevels` reads everything above it instead:
            // the zoomed-out drawings, where a style may keep what it never draws up
            // close - a reserve's hatch over half a district.
            let divisions = tree.subdivisions.filter { division in
                (resolution.map({ 24 - division.shift == $0 })
                    ?? (coarserLevels ? division.level > 0 : division.level == 0))
                    && grounds.contains(where: { division.near($0) })
            }
            // The drawing is read only for a tile with something near the ground: a whole
            // device map is gigabytes, often read off a card.
            guard !divisions.isEmpty, let rgnData = ImgContainer.read(rgn, from: img) else { continue }
            let region = try Region(rgnData, tile: tre.name)
            for division in divisions {
                try region.read(
                    division,
                    extendedAreasAndPoints: extendedAreasAndPoints,
                    tile: tre.name
                ) { kind, type, coords in
                    try tick()
                    guard coords.contains(where: { c in grounds.contains { $0.contains(c) } })
                    else { return }
                    emit(kind, type, coords, 24 - division.shift)
                }
            }
        }
    }
}
