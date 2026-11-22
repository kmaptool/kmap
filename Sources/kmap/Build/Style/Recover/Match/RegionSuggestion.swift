import Foundation

/// Chooses the regions whose OSM extracts identify a foreign map's codes.
///
/// Each piece of the map's ground goes to 1 extract: one in the cache where there is
/// one, else the smallest of the index over it. The ground a run needs is geometry
/// against the Geofabrik index; the ground to add after one goes by the codes it left
/// unsettled.
enum RegionSuggestion {
    /// Minimum drawn density inside a region, as a fraction of the map's own average.
    /// Sea, and a neighbour the map's rectangles merely overhang, hold almost no data.
    static let denseEnough = 0.2

    /// A region, and how its own ground stands to the map: the outline less what an
    /// extract before it holds, so a piece of ground counts once.
    struct Candidate {
        let region: Region
        /// Share of the region's own ground lying under the map's tiles.
        let inside: Double
        /// Share of the map's drawn data lying on the region's own ground.
        let share: Double
        /// The map's drawn density over this region against its own average: 1 is an
        /// ordinary piece of the map, near zero is empty tiles over a neighbour.
        let density: Double
        /// The map's drawn data inside the region, in bytes of RGN. An absolute
        /// measure, unlike `share`.
        let drawn: Double
        /// Share of the map's drawn data lying anywhere inside the region's outline.
        let whole: Double

        /// There is data, at no less than `denseEnough` of the map's average density.
        var isDrawnOn: Bool {
            share > 0 && density >= RegionSuggestion.denseEnough
        }

        /// Most of what the region holds of the map lies on its own ground, so its
        /// extract is the one to read for it. Where smaller extracts hold most of it,
        /// they are, and the whole region would be read for what is left between them.
        var standsAlone: Bool { share * 2 > whole }
    }

    /// Where a region's extract lands, in the build pipeline's own naming, so a
    /// download made here is the one a build finds.
    static func cacheDestination(for region: Region) -> URL {
        Paths.pbfCache.appendingPathComponent("\(FileTools.slugify(region.id)).osm.pbf")
    }

    /// Every extract in the cache with the ground it holds: the outline of the region it
    /// is, where the index knows it; else its header's box, which errs towards more
    /// ground. A file whose header does not read is no extract.
    static func cachedGrounds(index: RegionIndex?) -> [(file: URL, ground: Region, known: Bool)] {
        var regions: [String: Region] = [:]
        for region in index?.regions.values.filter({ $0.pbfURL != nil }) ?? [] {
            regions[cacheDestination(for: region).lastPathComponent] = region
        }
        var out: [(file: URL, ground: Region, known: Bool)] = []
        // Through a link: macOS will not list a folder by its link's path.
        for url in FileTools.contents(of: FileTools.resolvingLinks(Paths.pbfCache), extension: "pbf") {
            let reader = PBFReader(url: url)
            guard reader.opensAsAnExtract() else { continue }
            if let region = regions[url.lastPathComponent] {
                out.append((url, region, true))
                continue
            }
            guard let header = (try? reader.headerBBox()) ?? nil else { continue }
            let bbox = BBox(minLon: header.minLon, minLat: header.minLat, maxLon: header.maxLon, maxLat: header.maxLat)
            guard bbox.isValid else { continue }
            let name = url.lastPathComponent
            out.append(
                (url, Region(id: name, name: name, parentID: nil, pbfURL: nil, bbox: bbox, boxes: [bbox]), false)
            )
        }
        return out.sorted { $0.file.path < $1.file.path }
    }

    /// Cached extracts the map is drawn on, the one holding most of the map first, each
    /// with the region it is where the index knows it.
    ///
    /// A region's outline says where its data is, so any of the map's on it is read. A
    /// header's box says less, and is held to the measure of a download.
    static func cachedExtracts(drawnOn drawn: DrawnGround, index: RegionIndex?) -> [(file: URL, outline: Region?)] {
        cachedHolders(drawnOn: drawn, index: index).map { ($0.file, $0.known ? $0.ground : nil) }
    }

    /// The same extracts with the ground each holds.
    static func cachedHolders(
        drawnOn drawn: DrawnGround,
        index: RegionIndex?
    ) -> [(file: URL, ground: Region, known: Bool)] {
        var out: [(file: URL, ground: Region, known: Bool, drawn: Double)] = []
        for cached in cachedGrounds(index: index) {
            let standing = stance(of: cached.ground, on: drawn)
            guard cached.known ? standing.share > 0 : standing.isDrawnOn else { continue }
            out.append((cached.file, cached.ground, cached.known, standing.drawn))
        }
        // Ties by name: the order decides which extract witnesses an element first.
        return out.sorted { ($0.drawn, $1.file.path) > ($1.drawn, $0.file.path) }.map { ($0.file, $0.ground, $0.known) }
    }
}
