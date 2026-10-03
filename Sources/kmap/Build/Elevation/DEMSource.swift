import Foundation

/// An elevation source kmap reads itself and keeps as `.hgt`, a directory per source.
protocol DEMSource: Sendable {
    /// The source id shown in the build screen and stored in settings.
    var sourceID: String { get }
    /// Cache directory under hgt/. The 1 or 3 in the name is load-bearing: the DEM
    /// layer's finest-source-wins ordering reads it, as does the dem-dists choice.
    var directoryName: String { get }
    /// Nodes per `.hgt` side: 3601 for 1 arc-second, 1201 for 3.
    var nodes: Int { get }
    /// The name the build log uses.
    var label: String { get }
    /// The lines the map carries where the licence asks to be credited.
    var credits: [String] { get }
}

extension DEMSource {
    var credits: [String] { [] }

    var cacheDirectory: URL {
        Paths.hgtCache.appendingPathComponent(directoryName, isDirectory: true)
    }

    func cachedTile(lat: Int, lon: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).hgt")
    }
}

/// A source published as 1 GeoTIFF per degree cell, with a list of the cells it holds.
protocol DEMTileSource: DEMSource {
    /// Cache directory name for downloads awaiting conversion.
    var tifCacheName: String { get }
    /// The survey's name, for the progress line.
    var family: String { get }
    func tileURL(lat: Int, lon: Int) -> URL?
    /// The source's own list of every tile it publishes, and its name in the cache.
    var tileListURL: URL? { get }
    var tileListCacheName: String { get }
    /// Cell names (`N44E034`) out of that list.
    func parseTileList(_ text: String) -> Set<String>
    /// Whether a download error means the source holds no such tile: open sea.
    func isAbsent(_ error: Error) -> Bool
}

extension DEMTileSource {
    /// 404, or 403, which S3 answers for a missing key when listing is not allowed.
    func isAbsent(_ error: Error) -> Bool {
        if case DownloadError.badStatus(let code) = error { return code == 404 || code == 403 }
        return false
    }

    /// A `.tif` lands here only complete and goes once its `.hgt` is verified; a rerun
    /// skips every cell that has one.
    var tifCacheDirectory: URL {
        Paths.cache.appendingPathComponent(tifCacheName, isDirectory: true)
    }

    func downloadedTif(lat: Int, lon: Int) -> URL {
        tifCacheDirectory.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).tif")
    }

    var tileListCache: URL {
        Paths.cache.appendingPathComponent("dem-index", isDirectory: true)
            .appendingPathComponent(tileListCacheName)
    }

    /// Cells the source publishes, from the cached list or the source; nil if neither
    /// answers, and the caller samples blind. The list is kept for good.
    func availableCells() async -> Set<String>? {
        let file = tileListCache
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let cells = parseTileList(text)
            if !cells.isEmpty { return cells }
        }
        guard let url = tileListURL else { return nil }
        // Retried: without the list every cell is sampled blind, sea included.
        guard let data = try? await Downloader.retrying({ try await Fetch.data(url) }),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let cells = parseTileList(text)
        guard !cells.isEmpty else { return nil }
        Paths.ensure(file.deletingLastPathComponent())
        try? FileTools.write(data, to: file)
        return cells
    }
}

/// Every source kmap reads itself, found by id.
enum DEMSources {
    static let tiled: [any DEMTileSource] = CopernicusDEM.flavors + [FABDEM.v12]
    static let all: [any DEMSource] = tiled + [GEDTM30.v12]

    /// Matched by whole id, never by prefix: "copernicus1" must not select "copernicus".
    static func named(_ id: String) -> (any DEMSource)? {
        all.first { $0.sourceID == id }
    }

    static func tiled(_ id: String) -> (any DEMTileSource)? {
        tiled.first { $0.sourceID == id }
    }
}
