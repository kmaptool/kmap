import Foundation

/// Copernicus DEM, fetched from its public buckets and converted to the `.hgt` files the
/// rest of the pipeline understands: GLO-30 at one arc-second, GLO-90 at three and a ninth
/// of the bytes. `HGTConversion` handles the two differences - a `.hgt` covers its degree
/// inclusively, and the bucket thins longitude sampling north of 50 deg.
enum CopernicusDEM {
    /// One resolution of the survey: its id in settings, its cache names, its grid.
    struct Flavor: DEMTileSource {
        let sourceID: String
        let directoryName: String
        let nodes: Int
        /// The public bucket, and the resolution field in its object names.
        let bucket: String
        let cogField: String
        let tifCacheName: String
        let label: String

        var family: String { "Copernicus" }
        var credits: [String] { [CopernicusDEM.credit] }

        /// The bucket's tile list: a stem per line, 1 MB.
        var tileListURL: URL? { URL(string: "https://\(bucket).s3.amazonaws.com/tileList.txt") }
        var tileListCacheName: String { "\(bucket)-tiles.txt" }

        func parseTileList(_ text: String) -> Set<String> { CopernicusDEM.parseTileList(text) }

        func tileURL(lat: Int, lon: Int) -> URL? {
            // The bucket's own name for the tile: the same corner, with the hemisphere
            // letters split apart by the fields it puts between them.
            let name = HGTName.of(lat: lat, lon: lon)
            let stem = "Copernicus_DSM_COG_\(cogField)_\(name.prefix(3))_00_\(name.suffix(4))_00_DEM"
            return URL(string: "https://\(bucket).s3.amazonaws.com/\(stem)/\(stem).tif")
        }
    }

    /// The attribution the Copernicus DEM licence asks for, in the map's alphabet.
    static let credit = "Copernicus DEM: (c) DLR 2010-2014, Airbus 2014-2018, ESA"

    // The ids follow the other sources' convention, the digit being arc-seconds as in
    // view1, srtm1 and alos1, rather than the survey's own metre branding.
    static let glo30 = Flavor(
        sourceID: "copernicus1",
        directoryName: "COP1",
        nodes: 3601,
        bucket: "copernicus-dem-30m",
        cogField: "10",
        tifCacheName: "copernicus-tif",
        label: "Copernicus GLO-30"
    )

    static let glo90 = Flavor(
        sourceID: "copernicus3",
        directoryName: "COP3",
        nodes: 1201,
        bucket: "copernicus-dem-90m",
        cogField: "30",
        tifCacheName: "copernicus3-tif",
        label: "Copernicus GLO-90"
    )

    static let flavors = [glo30, glo90]

    /// The spellings that reached disk before the convention settled - "copernicus" and
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
        try FileTools.write(text, to: url)
    }
}
