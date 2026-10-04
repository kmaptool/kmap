import Foundation

/// What the elevation for a map will cost to download, before anything is downloaded.
///
/// The cells are the very ones the build fetches, the regions' own boxes trimmed to
/// their outlines through `ElevationFootprint`, and the sources are costed as a chain,
/// each over what the ones listed before it leave behind, which is how the build fetches
/// them. A tiled source publishes the list of every tile it holds, so which cells are
/// open sea is read, not guessed; Viewfinder's coverage index names the exact zone
/// archives. A small fetch has every file asked its size, and only a large one is sampled.
enum ElevationCost {
    /// What a source will cost, as far as it can be known.
    struct Estimate: Equatable {
        /// The source this line is about, as the form names it.
        let source: String
        /// Degree cells the map covers, after the outline trim.
        let cells: Int
        /// Of those, cells this source already holds on disk.
        let cached: Int
        /// Cells this source is asked for: not cached, and not already settled by a
        /// source listed before it.
        let wanted: Int
        /// Of those, cells the source actually publishes. The rest are open sea or
        /// ground it does not carry, and cost nothing.
        let published: Int
        /// What fetching them will come to, where that can be known.
        let bytes: Int64?
        /// True when every file was asked its size; false when the figure is a mean of
        /// `sampled` probes times the count.
        let exact: Bool
        /// How many real files were asked their size to arrive at the figure.
        let sampled: Int
        /// Archives to fetch, for sources shipping zones rather than single cells.
        let archives: Int
        /// Why there is no figure, where there is none.
        let note: String?
    }

    /// Up to this many files, every one is asked its size and the figure is exact.
    static let exactLimit = 48
    /// Past it, this many probes are spread across the list, south to north, so the
    /// thinner high-latitude tiles weigh in at their true share.
    static let sampleSize = 16
    /// Size probes in flight at once.
    private static let lanes = 6

    // MARK: Test seams

    /// The size probe and the coverage lists, replaceable so tests run without the
    /// network. Estimation is read-only, so a test overriding these touches no cache.
    private struct Seams {
        var probeSize: @Sendable (URL) async throws -> Int64 = { try await Downloader.probe($0).size }
        var tileCoverage: @Sendable (any DEMTileSource) async -> Set<String>? = {
            await $0.availableCells()
        }
        var gedtmRead: @Sendable (GEDTM30) -> GEDTM30.Read = { $0.remote() }
        var viewfinderIndex: @Sendable (Int) async -> ViewfinderDEM.Index? = { resolution in
            if let index = ViewfinderDEM.Index.load(ViewfinderDEM.indexFile(resolution)) {
                return index
            }
            return try? await ViewfinderDEM.index(resolution) { _ in }
        }
    }

    private static let seams = Locked(Seams())

    static var probeSize: @Sendable (URL) async throws -> Int64 {
        get { seams.withLock { $0.probeSize } }
        set { seams.withLock { $0.probeSize = newValue } }
    }

    static var tileCoverage: @Sendable (any DEMTileSource) async -> Set<String>? {
        get { seams.withLock { $0.tileCoverage } }
        set { seams.withLock { $0.tileCoverage = newValue } }
    }

    static var gedtmRead: @Sendable (GEDTM30) -> GEDTM30.Read {
        get { seams.withLock { $0.gedtmRead } }
        set { seams.withLock { $0.gedtmRead = newValue } }
    }

    static var viewfinderIndex: @Sendable (Int) async -> ViewfinderDEM.Index? {
        get { seams.withLock { $0.viewfinderIndex } }
        set { seams.withLock { $0.viewfinderIndex = newValue } }
    }

    // MARK: The cells

    /// The degree cells the build will fetch for these regions: boxes trimmed to the
    /// region outlines, exactly as the pipeline computes them.
    static func cells(of regions: [Region]) async -> [(lat: Int, lon: Int)] {
        await ElevationFootprint.cells(of: regions)
    }

    // MARK: The estimate

    /// 1 line per source, in the order the list names them, which is the order the
    /// build fetches them in, each source asked only for what the ones before it leave
    /// behind. The lines therefore add up rather than each repeating the whole map.
    static func estimate(sources: String, regions: [Region]) async -> [Estimate] {
        await estimate(sources: sources, cells: cells(of: regions))
    }

    static func estimate(
        sources: String,
        cells wanted: [(lat: Int, lon: Int)]
    ) async -> [Estimate] {
        guard !wanted.isEmpty else { return [] }
        var out: [Estimate] = []
        // Cells an earlier source already holds or will fetch; nothing later pays for them.
        var covered = Set<String>()
        for id in CopernicusDEM.canonicalSourceList(sources).split(separator: ",") {
            out.append(await estimate(source: String(id), cells: wanted, covered: &covered))
        }
        return out
    }

    private static func estimate(
        source: String,
        cells: [(lat: Int, lon: Int)],
        covered: inout Set<String>
    ) async -> Estimate {
        if let tiled = DEMSources.tiled(source) {
            return await perCell(tiled, cells: cells, covered: &covered)
        }
        if let gedtm = DEMSources.named(source) as? GEDTM30 {
            return await gedtmCost(gedtm, cells: cells, covered: &covered)
        }
        if source.hasPrefix("view"), let resolution = Int(source.dropFirst(4)) {
            return await viewfinder(resolution, source: source, cells: cells, covered: &covered)
        }
        return Line(source: source, cells: cells.count, cached: 0, wanted: uncovered(cells, covered).count)
            .unknown(note: t("behind a login, so its size is only known once it starts"))
    }

    /// What every line of a source says alike; the rest is how the count came out.
    private struct Line {
        let source: String
        let cells: Int
        let cached: Int
        let wanted: Int

        /// Nothing to pay for.
        func free(note: String? = nil) -> Estimate {
            measured(published: 0, bytes: 0, exact: true, note: note)
        }

        /// No figure at all.
        func unknown(published: Int = 0, note: String) -> Estimate {
            measured(published: published, bytes: nil, exact: false, note: note)
        }

        func measured(
            published: Int,
            bytes: Int64?,
            exact: Bool,
            sampled: Int = 0,
            archives: Int = 0,
            note: String? = nil
        ) -> Estimate {
            Estimate(
                source: source,
                cells: cells,
                cached: cached,
                wanted: wanted,
                published: published,
                bytes: bytes,
                exact: exact,
                sampled: sampled,
                archives: archives,
                note: note
            )
        }
    }

    private static func uncovered(_ cells: [(lat: Int, lon: Int)], _ covered: Set<String>) -> [(lat: Int, lon: Int)] {
        cells.filter { !covered.contains(name(of: $0)) }
    }

    private static func name(of cell: (lat: Int, lon: Int)) -> String {
        HGTName.of(lat: cell.lat, lon: cell.lon)
    }

    // MARK: A GeoTIFF per degree

    /// Copernicus and FABDEM are 1 object per degree. The source's tile list says exactly
    /// which of the wanted cells it publishes; only their sizes are asked or sampled.
    private static func perCell(
        _ flavor: any DEMTileSource,
        cells: [(lat: Int, lon: Int)],
        covered: inout Set<String>
    ) async -> Estimate {
        // A converted or already-downloaded cell fetches nothing, and also settles the
        // cell for every source listed after this one.
        let cached = cells.filter {
            FileTools.exists(flavor.cachedTile(lat: $0.lat, lon: $0.lon))
                || FileTools.exists(flavor.downloadedTif(lat: $0.lat, lon: $0.lon))
        }
        covered.formUnion(cached.map(name(of:)))
        let toFetch = uncovered(cells, covered)
        let line = Line(source: flavor.sourceID, cells: cells.count, cached: cached.count, wanted: toFetch.count)
        guard !toFetch.isEmpty else { return line.free() }

        guard let available = await tileCoverage(flavor) else {
            // The list did not answer: sampled blind over every wanted cell, an absent
            // one counting as the 0 it costs.
            let (bytes, sampled) = await blindSample(toFetch, flavor: flavor)
            return line.measured(
                published: toFetch.count,
                bytes: bytes,
                exact: false,
                sampled: sampled,
                note: bytes == nil
                    ? t("the source did not answer, so this is unmeasured")
                    : t("coverage list unavailable — a sampled guess")
            )
        }

        // South to north, so the sample takes the thinner high-latitude tiles in their
        // true share when it comes to that.
        let published = toFetch.filter { available.contains(name(of: $0)) }
            .sorted { $0.lat < $1.lat }
        covered.formUnion(published.map(name(of:)))
        guard !published.isEmpty else {
            return line.free(
                note: tn("the %d cell(s) left are open sea or unsurveyed — nothing to fetch", toFetch.count)
            )
        }
        let urls = published.compactMap { flavor.tileURL(lat: $0.lat, lon: $0.lon) }
        let (bytes, sampled, exact) = await size(of: urls)
        return line.measured(
            published: published.count,
            bytes: bytes,
            exact: exact,
            sampled: sampled,
            note: bytes == nil ? t("the source did not answer, so this is unmeasured") : nil
        )
    }

    /// For when the tile list cannot be had: a few probes spread across the map, an
    /// absent object counting as the 0 it costs.
    private static func blindSample(
        _ cells: [(lat: Int, lon: Int)],
        flavor: any DEMTileSource
    ) async -> (Int64?, Int) {
        let step = max(1, cells.count / sampleSize)
        var sizes: [Int64] = []
        for index in stride(from: 0, to: cells.count, by: step) where sizes.count < sampleSize {
            let cell = cells[index]
            guard let url = flavor.tileURL(lat: cell.lat, lon: cell.lon) else { continue }
            do {
                sizes.append(try await probeSize(url))
            } catch let error where flavor.isAbsent(error) {
                sizes.append(0)
            } catch {
                continue
            }
        }
        guard !sizes.isEmpty else { return (nil, 0) }
        let mean = sizes.reduce(0, +) / Int64(sizes.count)
        return (mean * Int64(cells.count), sizes.count)
    }

    // MARK: GEDTM30

    /// GEDTM30 is 1 file: the cost is the sizes of the tiles under the wanted cells, from
    /// its index.
    private static func gedtmCost(
        _ source: GEDTM30,
        cells: [(lat: Int, lon: Int)],
        covered: inout Set<String>
    ) async -> Estimate {
        let cached = cells.filter { FileTools.exists(source.cachedTile(lat: $0.lat, lon: $0.lon)) }
        covered.formUnion(cached.map(name(of:)))
        // Sea or outside the raster: free here, open to later sources.
        let toFetch = uncovered(cells, covered).filter { !source.holdsNothing(lat: $0.lat, lon: $0.lon) }
        let line = Line(source: source.sourceID, cells: cells.count, cached: cached.count, wanted: toFetch.count)
        guard !toFetch.isEmpty else { return line.free() }
        do {
            let read = gedtmRead(source)
            let layout = try await GEDTM30.parsing { try await GEDTM30.layout(read: read) }
            var tiles = Set<Int>()
            var published: [(lat: Int, lon: Int)] = []
            for cell in toFetch {
                let under = try layout.tiles(lat: cell.lat, lon: cell.lon, nodes: source.nodes)
                guard !under.isEmpty else { continue }
                published.append(cell)
                tiles.formUnion(under)
            }
            covered.formUnion(published.map(name(of:)))
            guard !published.isEmpty else {
                return line.free(
                    note: tn("the %d cell(s) left are open sea or unsurveyed — nothing to fetch", toFetch.count)
                )
            }
            let under = tiles
            let spans = try await GEDTM30.parsing { try await GEDTM30.spans(of: under, in: layout, read: read) }
            let bytes = spans.filter { !FileTools.exists(source.chunk($0.value)) }
                .reduce(Int64(0)) { $0 + Int64($1.value.count) }
            return line.measured(published: published.count, bytes: bytes, exact: true)
        } catch {
            return line.unknown(
                published: toFetch.count,
                note: t("the source did not answer, so this is unmeasured")
            )
        }
    }

    // MARK: Viewfinder

    /// Viewfinder publishes zones, not degrees: 1 archive can hold 60 tiles, so the
    /// cost is the sum of the zone archives touched. Which zone holds which degree is the
    /// coverage index, fetched when it is not already cached.
    private static func viewfinder(
        _ resolution: Int,
        source: String,
        cells: [(lat: Int, lon: Int)],
        covered: inout Set<String>
    ) async -> Estimate {
        let complete = cells.filter {
            ViewfinderDEM.isComplete(
                ViewfinderDEM.cachedTile(name(of: $0), resolution: resolution),
                resolution: resolution
            )
        }
        covered.formUnion(complete.map(name(of:)))
        let toFetch = uncovered(cells, covered)
        let line = Line(source: source, cells: cells.count, cached: complete.count, wanted: toFetch.count)
        guard !toFetch.isEmpty else { return line.free() }

        guard let index = await viewfinderIndex(resolution) else {
            return line.unknown(
                note: t(
                    "the coverage map could not be read, so which archives"
                        + " this needs is not known"
                )
            )
        }

        // 1 archive per zone however many of its tiles are wanted; a cell no zone
        // claims is unpublished, the far north and the open sea, and costs nothing.
        var zones: [String] = []
        var seen = Set<String>()
        var published: [(lat: Int, lon: Int)] = []
        for cell in toFetch {
            guard let zone = index.urls(for: name(of: cell)).first else { continue }
            published.append(cell)
            if seen.insert(zone).inserted { zones.append(zone) }
        }
        covered.formUnion(published.map(name(of:)))
        guard !zones.isEmpty else { return line.free(note: t("no archive covers this ground")) }

        let urls = zones.compactMap { URL(string: $0) }
            .filter { $0.scheme?.hasPrefix("http") == true }
        let (bytes, sampled, exact) = await size(of: urls)
        return line.measured(
            published: published.count,
            bytes: bytes,
            exact: exact,
            sampled: sampled,
            archives: zones.count,
            note: bytes == nil
                ? tn(
                    "%d archive(s) to fetch, of a size the server did not"
                        + " report",
                    zones.count
                )
                : nil
        )
    }

    // MARK: Asking the sizes

    /// The size of a set of files: every one asked when the set is small enough, a
    /// spread sample otherwise, a few probes in flight at a time.
    private static func size(of urls: [URL]) async -> (bytes: Int64?, sampled: Int, exact: Bool) {
        guard !urls.isEmpty else { return (0, 0, true) }
        let askAll = urls.count <= exactLimit
        var picked: [URL] = []
        if askAll {
            picked = urls
        } else {
            let step = max(1, urls.count / sampleSize)
            for index in stride(from: 0, to: urls.count, by: step) where picked.count < sampleSize {
                picked.append(urls[index])
            }
        }

        var sizes: [Int64] = []
        await withTaskGroup(of: Int64?.self) { group in
            var next = 0
            func launch() {
                let url = picked[next]
                group.addTask { try? await probeSize(url) }
                next += 1
            }
            while next < picked.count && next < lanes { launch() }
            while let result = await group.next() {
                if let size = result { sizes.append(size) }
                if next < picked.count { launch() }
            }
        }
        guard !sizes.isEmpty else { return (nil, 0, false) }
        if askAll && sizes.count == picked.count {
            return (sizes.reduce(0, +), sizes.count, true)
        }
        let mean = sizes.reduce(0, +) / Int64(sizes.count)
        return (mean * Int64(urls.count), sizes.count, false)
    }
}
