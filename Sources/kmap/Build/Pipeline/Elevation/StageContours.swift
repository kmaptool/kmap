import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a separate module outside Apple's platforms.
import FoundationNetworking
#endif

/// Stage 3, continued: traces contour lines from the elevation tiles and writes OSM summit
/// heights into the tiles the DEM layer reads. Both work one degree cell at a time, and
/// each cell gets its own reserved range of node and way ids.
extension BuildPipeline {
    /// Contour cells for the whole map, each clipped to its region's bounds, so regions
    /// far apart get contours over each of them and nothing in between.
    func contourCells() -> [BBox] {
        var seen = Set<String>()
        var out: [BBox] = []
        for region in recipe.regions {
            for cell in region.boxes.flatMap({ degreeCells(of: $0) }) {
                let key = String(format: "%.4f,%.4f,%.4f,%.4f",
                                 cell.minLat, cell.minLon, cell.maxLat, cell.maxLon)
                if seen.insert(key).inserted { out.append(cell) }
            }
        }
        let cells = out.isEmpty ? degreeCells(of: recipe.coverage) : out
        // A cell the elevation stage trimmed has no .hgt and traces nothing.
        guard let kept = outlineElevationCells else { return cells }
        let names = Set(kept.map { CopernicusDEM.cellName(lat: $0.lat, lon: $0.lon) })
        return cells.filter {
            names.contains(HGTName.of(lat: $0.minLat, lon: $0.minLon))
        }
    }

    private func degreeCells(of bbox: BBox) -> [BBox] {
        let snapped = bbox.snappedOutward()
        // Roughly 2 km, so contours run past the border and meet neighbouring maps.
        let margin = 0.02
        let clip = BBox(minLon: bbox.minLon - margin, minLat: bbox.minLat - margin,
                        maxLon: bbox.maxLon + margin, maxLat: bbox.maxLat + margin)

        var cells: [BBox] = []
        var lat = snapped.minLat
        while lat < snapped.maxLat {
            var lon = snapped.minLon
            while lon < snapped.maxLon {
                let cell = BBox(minLon: max(lon, clip.minLon),
                                minLat: max(lat, clip.minLat),
                                maxLon: min(lon + 1, clip.maxLon),
                                maxLat: min(lat + 1, clip.maxLat))
                // A cell the region only grazes can clip to nothing.
                if cell.maxLon - cell.minLon > 0.001, cell.maxLat - cell.minLat > 0.001 {
                    cells.append(cell)
                }
                lon += 1
            }
            lat += 1
        }
        return cells
    }

    /// Warns when a chosen elevation source needs a login that is missing or was refused.
    /// The build then falls back to the other sources listed.
    func warnIfCredentialsMissing() {
        let wanted = ElevationLogins.needed(for: recipe.demSources)
        guard wanted.contains(where: { !ElevationLogins.usable($0) }) else { return }

        log.warn("\(recipe.demSources) needs a login: srtm goes through USGS EarthExplorer"
                 + " (https://ers.cr.usgs.gov/register, not NASA Earthdata), alos through"
                 + " JAXA. Set it in Settings, or the build falls back to whatever else you"
                 + " listed.")
    }

    /// The outline of every chosen region as one mask, or nil if any outline is missing:
    /// clipping to a partial union would cut contours over real data.
    func regionMask() async -> GroundMask? {
        var rings: [RegionOutline.Ring] = []
        for region in recipe.regions {
            guard let some = await regionRings(region) else {
                log.warn("no outline for \(region.name) — contours will cover the whole"
                         + " rectangle, including ground outside the region")
                return nil
            }
            rings.append(contentsOf: some)
        }
        guard let mask = GroundMask(rings: rings) else { return nil }
        log.append("contours will be cut to the region outline(s)")
        return mask
    }

    /// A region's `.poly`, from the cache or from beside its extract on Geofabrik. It is
    /// the exact polygon the extract was cut with.
    func regionRings(_ region: Region) async -> [RegionOutline.Ring]? {
        await RegionOutline.rings(for: region)
    }

    func contourCell(_ cell: BBox, index: Int, mask: GroundMask?, directory: URL,
                             major: Int, medium: Int) async throws {
        // A non-overlapping id slice per cell, starting clear of the ids OSM itself uses.
        let nodeStart = ContourOutput.nodeIDBase + Int64(index) * ContourOutput.nodeIDSlice
        let wayStart = ContourOutput.wayIDBase + Int64(index) * ContourOutput.wayIDSlice
        let prefix = String(format: "contour%04d", index)

        // The clip is the cell, so ground the region only grazes is not traced.
        try Task.checkCancellation()

        let name = HGTName.of(lat: cell.minLat, lon: cell.minLon) + ".hgt"
        guard let tile = demSearchPaths()
            .map({ $0.appendingPathComponent(name) })
            .first(where: { FileTools.exists($0) }) else { return }

        let cellStarted = ContourTiming.now()
        do {
            let grid = try ContourTiming.measure("load") { try Contours.Grid(contentsOf: tile) }
            var tracer = Contours(grid: grid, step: recipe.contourInterval)
            tracer.clip = (minLat: cell.minLat, minLon: cell.minLon,
                           maxLat: cell.maxLat, maxLon: cell.maxLon)
            let raw = tracer.trace()
            let traced = ContourTiming.measure("split") { Contours.split(raw) }
            // Cut where they leave the region. Lines share no nodes, and the mask answers
            // identically for a coordinate in whichever cell asks, so seams stay in step.
            let lines = ContourTiming.measure("mask") { mask.map { $0.clip(traced) } ?? traced }
            guard !lines.isEmpty else { return }
            let output = directory.appendingPathComponent("\(prefix).osm.pbf")
            let counts = try ContourTiming.measure("write") {
                try ContourOutput.write(lines, to: output,
                                        nodeStart: nodeStart, wayStart: wayStart,
                                        major: major, medium: medium)
            }
            ContourTiming.cell(index: index, name: tile.lastPathComponent, start: cellStarted,
                               seconds: ContourTiming.now() - cellStarted, points: counts.nodes)
            log.append("\(prefix): \(counts.ways) contour(s), \(counts.nodes) node(s)"
                       + " from \(tile.lastPathComponent)")
        } catch {
            try rethrowIfCancelled(error)
            log.warn("\(prefix): \(error)")
        }
    }

    func hgtFileCount() -> Int {
        guard let walker = FileManager.default.enumerator(
            at: Paths.hgtCache, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        for case let url as URL in walker where url.pathExtension.lowercased() == "hgt" {
            count += 1
        }
        return count
    }

    /// Directories under the .hgt cache holding elevation files, finest first. mkgmap
    /// searches `--dem` paths in order and takes the first tile it finds.
    func demSearchPaths() -> [URL] {
        var directories = Set<URL>()
        guard let walker = FileManager.default.enumerator(
            at: Paths.hgtCache, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walker where url.pathExtension.lowercased() == "hgt" {
            directories.insert(url.deletingLastPathComponent())
        }
        // The cache is shared between builds and holds sources this one did not ask for,
        // so the chosen sources rank first or the DEM disagrees with the contours.
        let chosen = demSourceList
        func rank(_ url: URL) -> Int {
            let name = url.lastPathComponent.lowercased()
            // Copernicus directory names (COP1/COP3) differ from its source ids, so the
            // generic name match below cannot connect them.
            for flavor in CopernicusDEM.flavors
            where name == flavor.directoryName.lowercased() {
                if let index = chosen.firstIndex(of: flavor.sourceID) { return index }
            }
            if let index = chosen.firstIndex(of: name) { return index }
            // Sources not asked for still fill holes, matching resolution first, so a
            // 3-arc-second choice is not undone one cell at a time.
            let wantsOneArc = chosen.first.map { $0.contains("1") } ?? true
            return name.contains("1") == wantsOneArc ? 100 : 200
        }
        let cached = directories.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra == rb ? a.path < b.path : ra < rb
        }
        // Each burned directory is paired directly ahead of the cache it came from, so it
        // shadows only its own tiles and never outranks a finer source.
        return cached.flatMap { dir -> [URL] in
            let burned = burnedElevationDirectories.first {
                $0.lastPathComponent == dir.lastPathComponent
            }
            return [burned, dir].compactMap { $0 }
        }
    }

    /// Writes OSM summit heights into a private copy of the tiles the DEM layer takes, from
    /// the source it takes each from. The cache is shared, and contours read it untouched:
    /// a raised summit would trace as rings.
    func burnPeakElevations(extracts: [URL]) async {
        guard recipe.demLayer, recipe.fixSummits else { return }
        let sources = demSearchPaths()
        // The tiles the DEM stage will take, by the source it takes each from.
        var wanted: [URL: Set<String>] = [:]
        for cell in elevationCells() {
            let name = CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon)
            guard let source = sources.first(where: {
                FileTools.exists($0.appendingPathComponent(name + ".hgt"))
            }) else { continue }
            wanted[source, default: []].insert(name)
        }
        guard !wanted.isEmpty else { return }
        let root = workDirectory.appendingPathComponent("hgt-peaks", isDirectory: true)
        // A copy from an earlier attempt must not shadow the cache.
        FileTools.removeIfPresent(root)
        var burned: [URL] = []
        let peaks: [BurnPeaks.Peak]
        do {
            peaks = try BurnPeaks.peaks(in: extracts)
        } catch {
            // Cancelled rather than unreadable: nothing to say about it.
            guard !isCancelled, !Task.isCancelled else { return }
            log.warn("summit heights left out: \(error)")
            return
        }
        for (source, names) in wanted.sorted(by: { $0.key.path < $1.key.path }) {
            let destination = root.appendingPathComponent(source.lastPathComponent,
                                                          isDirectory: true)
            do {
                var burn = BurnPeaks(extracts: extracts, hgt: source, out: destination)
                burn.tiles = names
                let report = try burn.run(peaks: peaks)
                log.append("\(report.raised) summit height(s) written into"
                           + " \(report.written.count) tile(s) of \(source.lastPathComponent),"
                           + " \(report.rejected.count) rejected as bad OSM")
                if !report.written.isEmpty { burned.append(destination) }
            } catch {
                guard !isCancelled, !Task.isCancelled else { return }
                log.warn("summit heights left out of \(source.lastPathComponent): \(error)")
            }
        }
        burnedElevationDirectories = burned
    }

    /// Whether the finest cached elevation data is 1 arc-second.
    var hasOneArcSecondData: Bool {
        demSearchPaths().first.map {
            let p = $0.path.lowercased()
            return p.contains("view1") || p.contains("srtm1") || p.contains("alos1")
                || p.contains(CopernicusDEM.directoryName.lowercased())
        } ?? false
    }
}
