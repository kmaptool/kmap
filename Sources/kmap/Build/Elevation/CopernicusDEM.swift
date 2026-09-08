import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a module of its own outside Apple's platforms.
import FoundationNetworking
#endif

/// Copernicus DEM, fetched from its public buckets and converted to the `.hgt` files the
/// rest of the pipeline understands: GLO-30 at one arc-second, GLO-90 at three and a ninth
/// of the bytes. `HGTConversion` handles the two differences — a `.hgt` covers its degree
/// inclusively, and the bucket thins longitude sampling north of 50°.
enum CopernicusDEM {
    /// Whether a download error means the bucket holds no such tile — open sea, not a
    /// failure. 404 is the plain answer; 403 is what S3 says for a missing key when
    /// listing is not allowed. Anything else is a failure.
    static func isAbsent(_ error: Error) -> Bool {
        if case DownloadError.badStatus(let code) = error { return code == 404 || code == 403 }
        return false
    }


    /// One resolution of the survey: its id in settings, its cache names, its grid.
    struct Flavor {
        /// The source id shown in the build screen and stored in settings.
        let sourceID: String
        /// Cache directory under hgt/. The 1 or 3 in the name is load-bearing: the DEM
        /// layer's finest-source-wins ordering reads it, as does the dem-dists choice.
        let directoryName: String
        /// Nodes per `.hgt` side: 3601 for one arc-second, 1201 for three.
        let nodes: Int
        /// The public bucket, and the resolution field in its object names.
        let bucket: String
        let cogField: String
        /// Where a downloaded GeoTIFF waits for its conversion; see tifCacheDirectory.
        let tifCacheName: String

        var cacheDirectory: URL {
            Paths.hgtCache.appendingPathComponent(directoryName, isDirectory: true)
        }

        func cachedTile(lat: Int, lon: Int) -> URL {
            cacheDirectory.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).hgt")
        }

        /// Where a downloaded GeoTIFF waits for its conversion. A cache, not scratch: a
        /// `.tif` appears here only complete, a rerun skips every cell that has one, and
        /// each is deleted once its `.hgt` is written and verified. One per resolution.
        var tifCacheDirectory: URL {
            Paths.cache.appendingPathComponent(tifCacheName, isDirectory: true)
        }

        func downloadedTif(lat: Int, lon: Int) -> URL {
            tifCacheDirectory.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).tif")
        }

        func tileURL(lat: Int, lon: Int) -> URL? {
            // The bucket's own name for the tile: the same corner, with the hemisphere
            // letters split apart by the fields it puts between them.
            let name = HGTName.of(lat: lat, lon: lon)
            let stem = "Copernicus_DSM_COG_\(cogField)_\(name.prefix(3))_00_\(name.suffix(4))_00_DEM"
            return URL(string: "https://\(bucket).s3.amazonaws.com/\(stem)/\(stem).tif")
        }
    }

    // The ids follow the other sources' convention, the digit being arc-seconds as in
    // view1, srtm1 and alos1, rather than the survey's own metre branding.
    static let glo30 = Flavor(sourceID: "copernicus1", directoryName: "COP1",
                              nodes: 3601, bucket: "copernicus-dem-30m",
                              cogField: "10", tifCacheName: "copernicus-tif")

    static let glo90 = Flavor(sourceID: "copernicus3", directoryName: "COP3",
                              nodes: 1201, bucket: "copernicus-dem-90m",
                              cogField: "30", tifCacheName: "copernicus3-tif")

    static let flavors = [glo30, glo90]

    /// The spellings that reached disk before the convention settled — "copernicus" and
    /// "copernicus90". Both keep working, and are resolved here.
    static func canonicalSourceID(_ id: String) -> String {
        switch id {
        case "copernicus": return glo30.sourceID
        case "copernicus90": return glo90.sourceID
        default: return id
        }
    }

    /// The same over a whole comma-separated setting, as screens and flags hold it.
    static func canonicalSourceList(_ csv: String) -> String {
        csv.lowercased().split(separator: ",")
            .map { canonicalSourceID($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }

    // The GLO-30 spellings, for the parts of the pipeline that only mean GLO-30.
    static let sourceID = glo30.sourceID
    static let directoryName = glo30.directoryName
    static var cacheDirectory: URL { glo30.cacheDirectory }
    static var tifCacheDirectory: URL { glo30.tifCacheDirectory }

    /// `N44E034`, the naming every consumer in this pipeline expects.
    static func cellName(lat: Int, lon: Int) -> String { HGTName.of(lat: lat, lon: lon) }

    static func cachedTile(lat: Int, lon: Int) -> URL { glo30.cachedTile(lat: lat, lon: lon) }
    static func downloadedTif(lat: Int, lon: Int) -> URL { glo30.downloadedTif(lat: lat, lon: lon) }
    static func tileURL(lat: Int, lon: Int) -> URL? { glo30.tileURL(lat: lat, lon: lon) }

    // MARK: What the bucket holds

    /// The bucket's own list of every tile it publishes, one stem per line. Ground the
    /// survey covers has a tile; open sea and the few unreleased areas have none. About
    /// twenty-six thousand lines, a megabyte, cached beside the other indexes.
    static func tileListURL(_ flavor: Flavor) -> URL? {
        URL(string: "https://\(flavor.bucket).s3.amazonaws.com/tileList.txt")
    }

    static func tileListCache(_ flavor: Flavor) -> URL {
        Paths.cache.appendingPathComponent("dem-index", isDirectory: true)
            .appendingPathComponent("\(flavor.bucket)-tiles.txt")
    }

    /// Cell names (`N44E034`) out of the list's stems
    /// (`Copernicus_DSM_COG_10_N44_00_E034_00_DEM`).
    static func parseTileList(_ text: String) -> Set<String> {
        var out = Set<String>()
        // The list comes with CRLF endings, and in a Swift string "\r\n" is one
        // character that "\n" alone does not match; isNewline splits it correctly.
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "_")
            guard fields.count >= 7 else { continue }
            out.insert(String(fields[4] + fields[6]))
        }
        return out
    }

    /// Which cells the bucket publishes, from the cache or the bucket itself. Nil when it
    /// cannot be had, and the caller falls back to sampling blind. The survey does not
    /// change, so a fetched list is kept for good.
    static func availableCells(_ flavor: Flavor) async -> Set<String>? {
        let file = tileListCache(flavor)
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let cells = parseTileList(text)
            if !cells.isEmpty { return cells }
        }
        guard let url = tileListURL(flavor) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let cells = parseTileList(text)
        guard !cells.isEmpty else { return nil }
        Paths.ensure(file.deletingLastPathComponent())
        try? data.write(to: file, options: .atomic)
        return cells
    }

    /// An osmosis `.poly` rectangle. pyhgtmap discards `--area` once handed a file to
    /// process, recomputing the area from the file, so a polygon is the only way to keep
    /// contours inside the region rather than covering whole degrees.
    static func writeClipPolygon(_ box: BBox, to url: URL) throws {
        let text = """
        kmap-clip
        1
           \(box.minLon)  \(box.minLat)
           \(box.maxLon)  \(box.minLat)
           \(box.maxLon)  \(box.maxLat)
           \(box.minLon)  \(box.maxLat)
           \(box.minLon)  \(box.minLat)
        END
        END

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
