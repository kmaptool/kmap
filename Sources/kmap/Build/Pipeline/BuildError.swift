import Foundation

enum BuildError: Error, LocalizedError {
    case missingTool(String)
    case notDownloadable(String)
    case noBoundingBox(String)
    case noContours(String)
    case noElevationTiles
    case splitterOutput(String)
    case noTiles
    case tileTooDense(Int, failed: [Int])
    case noOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingTool(let name):
            return t("missing tool: %@", name)
        case .notDownloadable(let name):
            return t("%@ has no .osm.pbf download — pick one of its sub-regions", name)
        case .noBoundingBox(let name):
            return t("no bounding box known for %@, so elevation data cannot be fetched", name)
        case .noContours(let area):
            return t("no contour data was produced for %@ — the elevation source may not"
                   + " cover it", area)
        case .noElevationTiles:
            return t("no .hgt elevation tiles were downloaded, so the DEM layer cannot be built")
        case .splitterOutput(let detail):
            return t("splitter did not produce what was expected: %@", detail)
        case .noTiles:
            return t("splitter produced no tiles")
        case .tileTooDense(let nodes, _):
            return t("a tile still overflows Garmin's 16 MB drawing section at %dk"
                   + " nodes per tile — lower Nodes per tile in Settings and build again",
                   nodes / 1000)
        case .noOutput(let name):
            return t("mkgmap did not produce gmapsupp.img for %@", name)
        }
    }
}
