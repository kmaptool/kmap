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
    case javaOutOfMemory(Int)
    case tooManyTiles(Int)
    case noOutput(String)
    case cutShort(String)
    case noGmap
    case alreadyBuilding(String)
    case outputInUse(String)
    case workFolderUnwritable(String)
    case workFolderNotKmaps(String)
    case styleKeptChanging
    case styleFolderGone(String)
    case unknownCodePage(Int)
    case familyIDOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .missingTool(let name):
            return t("missing tool: %@", name)
        case .notDownloadable(let name):
            return t("%@ has no .osm.pbf download — pick one of its sub-regions", name)
        case .noBoundingBox(let name):
            return t("no bounding box known for %@, so elevation data cannot be fetched", name)
        case .noContours(let area):
            return t(
                "no contour data was produced for %@ — the elevation source may not"
                    + " cover it",
                area
            )
        case .noElevationTiles:
            return t("no .hgt elevation tiles were downloaded, so the DEM layer cannot be built")
        case .splitterOutput(let detail):
            return t("splitter did not produce what was expected: %@", detail)
        case .noTiles:
            return t("splitter produced no tiles")
        case .tileTooDense(let nodes, _):
            return t(
                "a tile still overflows Garmin's 16 MB drawing section at %dk"
                    + " nodes per tile — lower Nodes per tile in Settings and build again",
                nodes / 1000
            )
        case .tooManyTiles(let count):
            return t(
                "%d tiles is more than one family's 9999 tile ids — raise Nodes per tile in Settings and build again",
                count
            )
        case .javaOutOfMemory(let gigabytes):
            return t(
                "mkgmap ran out of memory with %d GB of Java heap — raise Java heap in Settings,"
                    + " or lower Nodes per tile, and build again",
                gigabytes
            )
        case .noOutput(let name):
            return t("mkgmap did not produce gmapsupp.img for %@", name)
        case .cutShort(let name):
            return t("mkgmap left %@ cut short — is the disk full?", name)
        case .noGmap:
            return t("mkgmap did not produce the .gmap folder")
        case .styleKeptChanging:
            return t("other builds kept changing the shared style — build again when they are done")
        case .styleFolderGone(let path):
            return t("the style folder %@ is gone", path)
        case .familyIDOutOfRange(let id):
            return t("family id %d is not 1000 to 9999, which mkgmap's 8-digit tile ids need", id)
        case .unknownCodePage(let page):
            return t("mkgmap knows no code page %d — pick another for this map or its profile", page)
        case .outputInUse(let folder):
            return t("another build is writing into %@ — wait for it to end, or stop it", folder)
        case .workFolderUnwritable(let folder):
            return t("kmap cannot write in the work folder %@ — pick another in Settings or with --work", folder)
        case .workFolderNotKmaps(let folder):
            return t(
                "%@ is not kmap's work: if an earlier kmap left it, remove it; otherwise pick another work folder",
                folder
            )
        case .alreadyBuilding(let name):
            return t("another build of %@ is running — wait for it to end, or stop it", name)
        }
    }
}
