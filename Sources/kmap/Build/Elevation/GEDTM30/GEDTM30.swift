import Foundation

/// GEDTM30 v1.2 (OpenGeoHub): bare-earth terrain at 1 arc-second, 65S to 85N. CC BY 4.0.
///
/// 1 BigTIFF of 432 GB, read by HTTP range: the header, the index entries and the tiles
/// the cells need. Pixel centres sit on whole arc-seconds, so a node is a pixel. Values
/// are metres despite the SCALE 0.1 metadata.
struct GEDTM30: DEMSource {
    static let v12 = GEDTM30(
        url: URL(
            string: "https://s3.opengeohub.org/global/dtm/v1.2/"
                + "gedtm_rf_m_30m_s_20060101_20151231_go_epsg.4326.3855_v1.2.tif"
        )!
    )

    let url: URL
    /// Names the absence marks, so a newer edition is asked afresh.
    var edition = "v1.2"
    let sourceID = "gedtm1"
    let directoryName = "GED1"
    /// Settable for tests.
    var nodes = 3601
    let label = "GEDTM30"
    let credits = ["GEDTM30: OpenGeoHub, CC BY 4.0"]

    /// Fetched tiles awaiting conversion, as served. Named by position in the file, so a
    /// newer edition never reuses a stale chunk.
    var chunkDirectory: URL { Paths.cache.appendingPathComponent("gedtm-tiles", isDirectory: true) }

    func chunk(_ span: Span) -> URL {
        chunkDirectory.appendingPathComponent("\(span.offset)-\(span.count).deflate")
    }

    /// How long a chunk waits for the build that fetched it to come back.
    private static let chunkAge: TimeInterval = 7 * 86400

    /// Removes the chunks no build has touched for `chunkAge`.
    func dropStaleChunks() {
        let old = Date().addingTimeInterval(-Self.chunkAge)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: chunkDirectory.path) else { return }
        for name in names {
            let file = chunkDirectory.appendingPathComponent(name)
            if let modified = FileTools.modified(of: file), modified < old { FileTools.removeIfPresent(file) }
        }
    }

    /// Marks an all-sea cell so a rebuild skips it; later sources may still fill it.
    func seaMark(lat: Int, lon: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).\(edition).sea")
    }

    /// Marks a cell the raster does not hold whole (85N, 65S); later sources may fill it.
    func outsideMark(lat: Int, lon: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).\(edition).out")
    }

    /// Leaves `mark`, removing a sea mark that names no edition.
    func leave(_ mark: URL) throws {
        try FileTools.write(Data(), to: mark)
        let name = mark.lastPathComponent
        guard let cell = name.split(separator: ".").first, name.hasSuffix(".sea") else { return }
        FileTools.removeIfPresent(mark.deletingLastPathComponent().appendingPathComponent("\(cell).sea"))
    }

    /// Whether the cell is known to be sea or outside the raster.
    func holdsNothing(lat: Int, lon: Int) -> Bool {
        FileTools.exists(seaMark(lat: lat, lon: lon)) || FileTools.exists(outsideMark(lat: lat, lon: lon))
    }

    /// Whether the cell needs nothing more from this source.
    func isDone(lat: Int, lon: Int) -> Bool {
        FileTools.exists(cachedTile(lat: lat, lon: lon)) || holdsNothing(lat: lat, lon: lon)
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case notTIFF
        case unsupported(String)
        case truncated

        var description: String {
            switch self {
            case .notTIFF: "not a TIFF file"
            case .unsupported(let what): "unsupported GEDTM30 layout: \(what)"
            case .truncated: "a GEDTM30 tile ends early"
            }
        }

        var errorDescription: String? { description }
    }
}
