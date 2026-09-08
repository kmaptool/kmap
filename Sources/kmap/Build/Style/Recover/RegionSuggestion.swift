import Foundation

/// Chooses the region whose OSM extract identifies a foreign map's codes.
///
/// A style's codes repeat wherever it draws, so one region inside the map answers for
/// all of it. Geometry against the Geofabrik index only: no evidence, no rules.
enum RegionSuggestion {

    /// Minimum share of a region lying under the map's tiles for its extract to be
    /// worth downloading.
    static let mostlyInside = 0.6

    /// Minimum share of the map's drawn data a region must hold to count as ground.
    /// Border tiles overhang the outline into neighbours with next to nothing in them.
    static let drawsEnough = 0.02

    /// Shares of the map's drawn data that make a region ground on their own: at
    /// `drawsALot` a sliver of `inside` is also required, at `drawsAQuarter` the share
    /// stands alone.
    static let drawsALot = 0.1
    static let drawsAQuarter = 0.25

    /// Minimum drawn density inside a region, as a fraction of the map's own average.
    /// Rectangular tiles laid over an excluded neighbour cover it entirely yet hold
    /// almost no data.
    static let denseEnough = 0.2

    /// Where a map draws: one box per tile, weighed by that tile's RGN size in bytes.
    ///
    /// Every measure is taken against the tiles. `frame`, the rectangle around them
    /// all, covers ground no tile holds and is kept for prose only.
    struct DrawnGround {
        struct Spot {
            let box: BBox
            let weight: Double
        }
        let spots: [Spot]
        let frame: BBox
    }

    static func drawnGround(of img: URL) -> DrawnGround {
        let sizes = Dictionary(ImgContainer.directory(of: img)
            .filter { $0.ext.uppercased() == "RGN" }
            .map { ($0.name, Double($0.size)) }, uniquingKeysWith: max)
        var frame = BBox.empty
        var spots: [DrawnGround.Spot] = []
        for tile in MapCoverage.tiles(in: img) {
            frame.extend(lon: tile.minLon, lat: tile.minLat)
            frame.extend(lon: tile.maxLon, lat: tile.maxLat)
            spots.append(DrawnGround.Spot(
                box: BBox(minLon: tile.minLon, minLat: tile.minLat,
                          maxLon: tile.maxLon, maxLat: tile.maxLat),
                weight: sizes[tile.name] ?? 0))
        }
        // A container whose RGN sizes cannot be read is weighed by area instead:
        // wrong for border tiles, and never all zeros.
        if spots.allSatisfy({ $0.weight <= 0 }) {
            spots = spots.map { DrawnGround.Spot(box: $0.box,
                                                 weight: max($0.box.squareDegrees, 1e-9)) }
        }
        return DrawnGround(spots: spots, frame: frame)
    }

    /// A region worth downloading, and how it stands to the map.
    struct Candidate {
        let region: Region
        /// Share of the region lying under the map's tiles.
        let inside: Double
        /// Share of the map's drawn data lying inside the region.
        let share: Double
        /// The map's drawn density over this region against its own average: 1 is an
        /// ordinary piece of the map, near zero is empty tiles over a neighbour.
        let density: Double
        /// The map's drawn data inside the region, in bytes of RGN. An absolute
        /// measure, unlike `share`.
        let drawn: Double
        /// There is data, at no less than `denseEnough` of the map's average density.
        var isDrawnOn: Bool {
            share > 0 && density >= RegionSuggestion.denseEnough
        }
        var isInside: Bool { inside >= mostlyInside }
    }

    /// Measures how a region stands to the map: coverage, share, density and drawn
    /// bytes.
    static func stance(of region: Region, on drawn: DrawnGround) -> Candidate {
        let total = drawn.spots.reduce(0.0) { $0 + $1.weight }
        let wholeArea = drawn.spots.reduce(0.0) { $0 + $1.box.squareDegrees }
        // The map's data inside the region, tile by tile against the region's outline:
        // only the samples the outline holds carry a tile's weight in.
        var held = 0.0
        var heldArea = 0.0
        for spot in drawn.spots {
            guard spot.box.squareDegrees > 0,
                  region.boxes.contains(where: { $0.intersects(spot.box) })
                      || region.bbox.intersects(spot.box) else { continue }
            // A grid stepped to the tile, 6 to 24 per side, so a region smaller than
            // the tile still catches samples.
            let span = max(spot.box.maxLon - spot.box.minLon,
                           spot.box.maxLat - spot.box.minLat)
            let steps = max(6, min(24, Int(span * 2)))
            let cells = sampleCells(of: spot.box, steps: steps)
            let inside = cells.lazy.filter { region.holds(lat: $0.lat, lon: $0.lon) }.count
            held += spot.weight * Double(inside) / Double(cells.count)
            heldArea += spot.box.squareDegrees * Double(inside) / Double(cells.count)
        }
        // The region under the map's tiles, sampled the same way: coverage by a union
        // of tiles has no closed form, and every sample carries its own cell's area.
        var hit = 0.0
        var sampled = 0.0
        for box in ground(of: region) where box.squareDegrees > 0 {
            let cells = sampleCells(of: box)
            guard !cells.isEmpty else { continue }
            let cellWeight = box.squareDegrees / Double(cells.count)
            let near = drawn.spots.filter { $0.box.intersects(box) }
            for cell in cells where region.holds(lat: cell.lat, lon: cell.lon) {
                sampled += cellWeight
                if near.contains(where: { $0.box.contains(lat: cell.lat, lon: cell.lon) }) {
                    hit += cellWeight
                }
            }
        }
        let share = total > 0 ? held / total : 0
        let areaShare = wholeArea > 0 ? heldArea / wholeArea : 0
        return Candidate(region: region,
                         inside: sampled > 0 ? hit / sampled : 0,
                         share: share,
                         density: areaShare > 0 ? share / areaShare : 0,
                         drawn: held)
    }

    /// Regions whose OSM data would identify this map's codes, the ones holding most
    /// of the map first. Regions are measured on their outline's own boxes, one per
    /// ring: a single box around a region crossing the 180th meridian spans the globe.
    static func suggestedRegions(on drawn: DrawnGround, index: RegionIndex) -> [Candidate] {
        let total = drawn.spots.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        let downloadable = index.regions.values.filter { $0.pbfURL != nil }
        let leaves = downloadable.filter { !$0.hasChildren }

        func measure(_ region: Region) -> Candidate { stance(of: region, on: drawn) }

        func ranked(_ pool: [Candidate]) -> [Candidate] {
            pool.sorted { ($0.share, $1.region.id) > ($1.share, $0.region.id) }
        }

        // Leaves only while any qualify: a leaf identifies the same codes as the
        // region containing it. Measured only where the box meets the frame.
        let measured = leaves
            .filter { region in
                region.bbox.intersects(drawn.frame)
                    || region.boxes.contains { $0.intersects(drawn.frame) }
            }
            .map(measure)
        var out = ranked(measured.filter { $0.isInside && $0.isDrawnOn })

        // Topped up to at least four, with regions the map draws in: a large share, or
        // a smaller one backed by coverage.
        if out.count < 4 {
            let taken = Set(out.map(\.region.id))
            out += ranked(measured.filter {
                !taken.contains($0.region.id) && $0.isDrawnOn
                    && ($0.share >= drawsAQuarter
                        || ($0.share >= drawsALot && $0.inside >= 0.15)
                        || ($0.inside >= mostlyInside / 2 && $0.share >= drawsEnough))
            })
        }
        // A map smaller than every region: nothing lies inside it, so fall back to
        // whichever region holds the map's data.
        if out.isEmpty {
            out = ranked(measured.filter { $0.isDrawnOn && $0.share >= drawsEnough })
        }
        if out.isEmpty {
            out = ranked(measured.filter { $0.share > 0 })
        }
        // Somewhere the index holds only as part of something bigger.
        if out.isEmpty {
            out = ranked(downloadable.filter(\.hasChildren)
                .filter { $0.bbox.intersects(drawn.frame) }
                .map(measure).filter { $0.share > 0 })
        }
        return Array(out.prefix(12))
    }

    /// Minimum drawn data, in bytes of RGN, for a region to answer for the map's
    /// vocabulary. Measured on the map, not on the size of the extract file.
    static let enoughDrawn: Double = 24 * 1_048_576

    /// Picks the candidate to offer: among the regions the map stands on, the lightest
    /// extract holding at least `enoughDrawn`; failing that, the one holding the most.
    ///
    /// - Parameter weighed: candidates paired with their download size in bytes.
    static func worthDownloading(_ weighed: [(Candidate, Int64)]) -> Candidate? {
        let inside = weighed.filter(\.0.isInside)
        let pool = inside.isEmpty ? weighed : inside
        if let best = pool.filter({ $0.0.drawn >= enoughDrawn }).min(by: { $0.1 < $1.1 }) {
            return best.0
        }
        return pool.max(by: { ($0.0.drawn, $1.1) < ($1.0.drawn, $0.1) })?.0
    }

    /// The boxes a region actually stands on: one per ring of its outline, falling back
    /// to the single box for a region whose outline never parsed.
    private static func ground(of region: Region) -> [BBox] {
        region.boxes.isEmpty ? [region.bbox] : region.boxes
    }

    /// The frame as a `steps` by `steps` grid of cell-centre points. Coverage is
    /// counted in these rather than in area, whatever the shape of the outline.
    private static func sampleCells(of frame: BBox,
                                    steps: Int = 24) -> [(lat: Double, lon: Double)] {
        var out: [(lat: Double, lon: Double)] = []
        out.reserveCapacity(steps * steps)
        for row in 0..<steps {
            for column in 0..<steps {
                let f = (Double(row) + 0.5) / Double(steps)
                let g = (Double(column) + 0.5) / Double(steps)
                out.append((lat: frame.minLat + f * (frame.maxLat - frame.minLat),
                            lon: frame.minLon + g * (frame.maxLon - frame.minLon)))
            }
        }
        return out
    }

    /// Where a region's extract lands, in the build pipeline's own naming, so a
    /// download made here is the one a build finds.
    static func cacheDestination(for region: Region) -> URL {
        Paths.pbfCache.appendingPathComponent("\(FileTools.slugify(region.id)).osm.pbf")
    }

    /// Cached extracts the map is drawn on, the one holding most of the map first.
    ///
    /// Held to the same measure as a download. The extract's header box stands in for
    /// an outline, which errs only towards keeping a marginal extract.
    static func cachedExtracts(drawnOn drawn: DrawnGround) -> [URL] {
        var out: [(URL, Double)] = []
        for url in FileTools.contents(of: Paths.pbfCache, extension: "pbf") {
            guard let box = try? PBFReader(url: url).headerBBox() else { continue }
            let bbox = BBox(minLon: box.minLon, minLat: box.minLat,
                            maxLon: box.maxLon, maxLat: box.maxLat)
            guard bbox.isValid else { continue }
            let extract = Region(id: url.lastPathComponent, name: url.lastPathComponent,
                                 parentID: nil, pbfURL: nil, bbox: bbox, boxes: [bbox])
            let standing = stance(of: extract, on: drawn)
            guard standing.isDrawnOn else { continue }
            out.append((url, standing.drawn))
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
