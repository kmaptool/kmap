import Foundation

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
    /// answers. A list older than `DEMTileList.maxAge` is asked for again; the old one
    /// serves if that fails.
    func availableCells() async -> Set<String>? {
        let file = tileListCache
        var kept: Set<String>?
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let cells = parseTileList(text)
            if !cells.isEmpty {
                guard DEMTileList.isStale(modified: FileTools.modified(of: file), now: Date()) else { return cells }
                kept = cells
            }
        }
        guard let url = tileListURL else { return kept }
        // Retried only with no list at all: an old list is good enough to build on.
        let data =
            kept == nil
            ? try? await Downloader.retrying({ try await Fetch.data(url) })
            : try? await Fetch.data(url)
        guard let data, let text = String(data: data, encoding: .utf8), case let cells = parseTileList(text),
            !cells.isEmpty
        else {
            if kept != nil { DEMTileList.postpone(file, from: Date()) }
            return kept
        }
        Paths.ensure(file.deletingLastPathComponent())
        try? FileTools.write(data, to: file)
        return cells
    }
}
