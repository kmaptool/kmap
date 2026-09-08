import Foundation

/// The elevation cells staged for mkgmap's DEM layer.
extension BuildPipeline {
    /// One directory holding exactly the elevation cells inside the regions' outlines, so
    /// mkgmap shades no ground the map does not cover. Each cell is linked, or copied, from
    /// the first `demSearchPaths()` directory holding it, so burned copies shadow originals.
    func stageDEMCells() -> [URL] {   // internal for DEMStagingTests
        let ranked = demSearchPaths()
        guard !ranked.isEmpty else { return [] }
        let staged = recipe.workDirectory.appendingPathComponent("dem-cells", isDirectory: true)
        FileTools.removeIfPresent(staged)
        Paths.ensure(staged)
        var linked = 0
        for cell in elevationCells() {
            let name = CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon) + ".hgt"
            guard let found = ranked.first(where: {
                FileTools.exists($0.appendingPathComponent(name))
            }) else { continue }
            // Counted only once the link or copy exists: without the symlink privilege on
            // Windows every link fails, and an empty --dem path yields flat relief.
            do {
                try FileManager.default.createSymbolicLink(
                    at: staged.appendingPathComponent(name),
                    withDestinationURL: found.appendingPathComponent(name))
                linked += 1
            } catch {
                if (try? FileManager.default.copyItem(
                    at: found.appendingPathComponent(name),
                    to: staged.appendingPathComponent(name))) != nil {
                    linked += 1
                }
            }
        }
        guard linked > 0 else { return [] }
        return [staged]
    }
}
