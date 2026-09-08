import Foundation

/// What the elevation for a map will cost to download, before anything is downloaded.
///
/// The cells are the very ones the build fetches — the regions' own boxes, trimmed to
/// their outlines through `ElevationFootprint` — and the sources are costed as a chain,
/// each over what the ones listed before it leave behind, which is how the build fetches
/// them. Copernicus publishes the list of every tile it holds, so which cells are open
/// sea is read, not guessed; Viewfinder's coverage index names the exact zone archives.
/// A small fetch has every file asked its size, and only a large one is sampled.
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
    static var probeSize: (URL) async throws -> Int64 = { try await Downloader.probe($0).size }
    static var copernicusCoverage: (CopernicusDEM.Flavor) async -> Set<String>?
        = { await CopernicusDEM.availableCells($0) }
    static var viewfinderIndex: (Int) async -> ViewfinderDEM.Index? = { resolution in
        if let index = ViewfinderDEM.Index.load(ViewfinderDEM.indexFile(resolution)) {
            return index
        }
        return try? await ViewfinderDEM.index(resolution,
                                              downloader: Downloader(log: Log()),
                                              log: { _ in })
    }

    // MARK: The cells

    /// The degree cells the build will fetch for these regions: boxes trimmed to the
    /// region outlines, exactly as the pipeline computes them.
    static func cells(of regions: [Region]) async -> [(lat: Int, lon: Int)] {
        await ElevationFootprint.cells(of: regions)
    }

    // MARK: The estimate

    /// One line per source, in the order the list names them — which is the order the
    /// build fetches them in, each source asked only for what the ones before it leave
    /// behind. The lines therefore add up rather than each repeating the whole map.
    static func estimate(sources: String, regions: [Region]) async -> [Estimate] {
        await estimate(sources: sources, cells: cells(of: regions))
    }

    static func estimate(sources: String,
                         cells wanted: [(lat: Int, lon: Int)]) async -> [Estimate] {
        guard !wanted.isEmpty else { return [] }
        var out: [Estimate] = []
        // Cells an earlier source already holds or will fetch; nothing later pays for them.
        var covered = Set<String>()
        for id in CopernicusDEM.canonicalSourceList(sources)
            .split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) })
        where !id.isEmpty {
            out.append(await estimate(source: id, cells: wanted, covered: &covered))
        }
        return out
    }

    private static func estimate(source: String, cells: [(lat: Int, lon: Int)],
                                 covered: inout Set<String>) async -> Estimate {
        if let flavor = CopernicusDEM.flavors.first(where: { $0.sourceID == source }) {
            return await copernicus(flavor, cells: cells, covered: &covered)
        }
        if source.hasPrefix("view"), let resolution = Int(source.dropFirst(4)) {
            return await viewfinder(resolution, source: source, cells: cells,
                                    covered: &covered)
        }
        let wanted = cells.filter { !covered.contains(name(of: $0)) }.count
        return Estimate(source: source, cells: cells.count, cached: 0, wanted: wanted,
                        published: 0, bytes: nil, exact: false, sampled: 0, archives: 0,
                        note: t("behind a login, so its size is only known once it starts"))
    }

    private static func name(of cell: (lat: Int, lon: Int)) -> String {
        CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon)
    }

    // MARK: Copernicus

    /// Copernicus is one object per degree. The bucket's tile list says exactly which of
    /// the wanted cells it publishes; only their sizes are asked or sampled.
    private static func copernicus(_ flavor: CopernicusDEM.Flavor,
                                   cells: [(lat: Int, lon: Int)],
                                   covered: inout Set<String>) async -> Estimate {
        // A converted or already-downloaded cell fetches nothing, and also settles the
        // cell for every source listed after this one.
        let cached = cells.filter {
            FileTools.exists(flavor.cachedTile(lat: $0.lat, lon: $0.lon))
                || FileTools.exists(flavor.downloadedTif(lat: $0.lat, lon: $0.lon))
        }
        covered.formUnion(cached.map(name(of:)))
        let toFetch = cells.filter { !covered.contains(name(of: $0)) }
        guard !toFetch.isEmpty else {
            return Estimate(source: flavor.sourceID, cells: cells.count,
                            cached: cached.count, wanted: 0, published: 0, bytes: 0,
                            exact: true, sampled: 0, archives: 0, note: nil)
        }

        guard let available = await copernicusCoverage(flavor) else {
            // The list did not answer: sampled blind over every wanted cell, with the
            // absent ones counted as the zero they cost, as the estimate always used to.
            let (bytes, sampled) = await blindSample(toFetch, flavor: flavor)
            return Estimate(source: flavor.sourceID, cells: cells.count,
                            cached: cached.count, wanted: toFetch.count,
                            published: toFetch.count, bytes: bytes,
                            exact: false, sampled: sampled, archives: 0,
                            note: bytes == nil
                                ? t("the bucket did not answer, so this is unmeasured")
                                : t("coverage list unavailable — a sampled guess"))
        }

        // South to north, so the sample takes the thinner high-latitude tiles in their
        // true share when it comes to that.
        let published = toFetch.filter { available.contains(name(of: $0)) }
            .sorted { $0.lat < $1.lat }
        covered.formUnion(published.map(name(of:)))
        guard !published.isEmpty else {
            return Estimate(source: flavor.sourceID, cells: cells.count,
                            cached: cached.count, wanted: toFetch.count, published: 0,
                            bytes: 0, exact: true, sampled: 0, archives: 0,
                            note: tn("the %d cell(s) left are open sea or unsurveyed"
                                   + " — nothing to fetch", toFetch.count))
        }
        let urls = published.compactMap { flavor.tileURL(lat: $0.lat, lon: $0.lon) }
        let (bytes, sampled, exact) = await size(of: urls)
        return Estimate(source: flavor.sourceID, cells: cells.count,
                        cached: cached.count, wanted: toFetch.count,
                        published: published.count, bytes: bytes,
                        exact: exact, sampled: sampled, archives: 0,
                        note: bytes == nil
                            ? t("the bucket did not answer, so this is unmeasured") : nil)
    }

    /// The old way, kept for when the tile list cannot be had: a few probes spread
    /// across the map, an absent object counting as the zero it costs.
    private static func blindSample(_ cells: [(lat: Int, lon: Int)],
                                    flavor: CopernicusDEM.Flavor) async -> (Int64?, Int) {
        let step = max(1, cells.count / sampleSize)
        var sizes: [Int64] = []
        for index in stride(from: 0, to: cells.count, by: step)
        where sizes.count < sampleSize {
            let cell = cells[index]
            guard let url = flavor.tileURL(lat: cell.lat, lon: cell.lon) else { continue }
            do {
                sizes.append(try await probeSize(url))
            } catch let error where CopernicusDEM.isAbsent(error) {
                sizes.append(0)
            } catch {
                continue
            }
        }
        guard !sizes.isEmpty else { return (nil, 0) }
        let mean = sizes.reduce(0, +) / Int64(sizes.count)
        return (mean * Int64(cells.count), sizes.count)
    }

    // MARK: Viewfinder

    /// Viewfinder publishes zones, not degrees: one archive can hold sixty tiles, so the
    /// cost is the sum of the zone archives touched. Which zone holds which degree is the
    /// coverage index, fetched when it is not already cached.
    private static func viewfinder(_ resolution: Int, source: String,
                                   cells: [(lat: Int, lon: Int)],
                                   covered: inout Set<String>) async -> Estimate {
        let complete = cells.filter {
            ViewfinderDEM.isComplete(
                ViewfinderDEM.cachedTile(name(of: $0), resolution: resolution),
                resolution: resolution)
        }
        covered.formUnion(complete.map(name(of:)))
        let toFetch = cells.filter { !covered.contains(name(of: $0)) }
        guard !toFetch.isEmpty else {
            return Estimate(source: source, cells: cells.count, cached: complete.count,
                            wanted: 0, published: 0, bytes: 0, exact: true, sampled: 0,
                            archives: 0, note: nil)
        }

        guard let index = await viewfinderIndex(resolution) else {
            return Estimate(source: source, cells: cells.count, cached: complete.count,
                            wanted: toFetch.count, published: 0, bytes: nil,
                            exact: false, sampled: 0, archives: 0,
                            note: t("the coverage map could not be read, so which archives"
                                  + " this needs is not known"))
        }

        // One archive per zone however many of its tiles are wanted; a cell no zone
        // claims is unpublished — the far north and the open sea — and costs nothing.
        var zones: [String] = []
        var seen = Set<String>()
        var published: [(lat: Int, lon: Int)] = []
        for cell in toFetch {
            guard let zone = index.urls(for: name(of: cell)).first else { continue }
            published.append(cell)
            if seen.insert(zone).inserted { zones.append(zone) }
        }
        covered.formUnion(published.map(name(of:)))
        guard !zones.isEmpty else {
            return Estimate(source: source, cells: cells.count, cached: complete.count,
                            wanted: toFetch.count, published: 0, bytes: 0, exact: true,
                            sampled: 0, archives: 0,
                            note: t("no archive covers this ground"))
        }

        let urls = zones.compactMap { URL(string: $0) }
            .filter { $0.scheme?.hasPrefix("http") == true }
        let (bytes, sampled, exact) = await size(of: urls)
        return Estimate(source: source, cells: cells.count, cached: complete.count,
                        wanted: toFetch.count, published: published.count,
                        bytes: bytes, exact: exact,
                        sampled: sampled, archives: zones.count,
                        note: bytes == nil
                            ? tn("%d archive(s) to fetch, of a size the server did not"
                               + " report", zones.count)
                            : nil)
    }

    // MARK: Asking the sizes

    /// The size of a set of files: every one asked when the set is small enough, a
    /// spread sample otherwise, a few probes in flight at a time.
    private static func size(of urls: [URL]) async -> (bytes: Int64?, sampled: Int,
                                                       exact: Bool) {
        guard !urls.isEmpty else { return (0, 0, true) }
        let askAll = urls.count <= exactLimit
        var picked: [URL] = []
        if askAll {
            picked = urls
        } else {
            let step = max(1, urls.count / sampleSize)
            for index in stride(from: 0, to: urls.count, by: step)
            where picked.count < sampleSize {
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
