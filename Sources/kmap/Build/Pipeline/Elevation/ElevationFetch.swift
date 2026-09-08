import Foundation

/// The fetch dispatcher: fills the `.hgt` cache from every source the recipe
/// names, in the order it names them.

extension BuildPipeline {
    /// Fills the `.hgt` cache from every source the recipe names.
    ///
    /// Copernicus and Viewfinder are kmap's own; only the two that need an account still go
    /// out through pyhgtmap.
    func fetchElevationTiles(covering bbox: BBox) async throws {
        for flavor in copernicusFlavors {
            try await fetchCopernicusTiles(flavor, covering: bbox,
                                           last: flavor.sourceID == copernicusFlavors.last?.sourceID)
        }
        if !viewfinderResolutions.isEmpty {
            try await fetchViewfinderTiles(covering: bbox)
        }
        guard !credentialedSources.isEmpty else { return }
        guard let pyhgtmap = toolchain.findPyhgtmap()?.url else {
            throw BuildError.missingTool(
                "pyhgtmap — needed to download \(credentialedSources.joined(separator: ", "))."
                + " Install it from the Toolchain screen, or choose copernicus or view1/view3")
        }
        let runner = makeRunner()
        // --area is a rectangle; the same osmosis .poly the extract was cut with gives
        // pyhgtmap the trim the other fetchers compute. With no outline, the box stands.
        var scope = ["--area=\(bbox.areaArgument)"]
        if let clip = await writeElevationClipPolygon() {
            scope = ["--polygon=\(clip.path)"]
        }
        try await runner.run(pyhgtmap.path, scope + [
            "--hgtdir=\(Paths.hgtCache.path)",
            "--sources=\(credentialedSources.joined(separator: ","))",
            "--download-only"
        ], cwd: workDirectory) { self.log.append($0) }

        elevationDownloadsFinished()
        elevationBuildStarted("converting")
        convertDownloadedGeoTIFF(covering: bbox, sources: credentialedSources)
    }
}
