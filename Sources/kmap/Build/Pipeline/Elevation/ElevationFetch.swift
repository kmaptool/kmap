import Foundation

/// The fetch dispatcher: fills the `.hgt` cache from every source the recipe
/// names, in the order it names them.

extension BuildPipeline {
    /// 1 fetch in the recipe's order: a direct source, a run of Viewfinder resolutions
    /// (chained per cell), or every pyhgtmap source at once.
    enum FetchStep {
        case direct(any DEMSource)
        case viewfinder([Int])
        case credentialed([String])
    }

    /// The recipe's sources as fetches, in its order, so each fills only the gaps of
    /// those before it. pyhgtmap takes its sources together, at the first one's place.
    var fetchSteps: [FetchStep] {
        var steps: [FetchStep] = []
        var credentialedPlaced = false
        for id in demSourceList {
            if let source = DEMSources.named(id) {
                steps.append(.direct(source))
            } else if id.hasPrefix("view"), let resolution = Int(id.dropFirst(4)), resolution == 1 || resolution == 3 {
                if case .viewfinder(let run)? = steps.last {
                    steps[steps.count - 1] = .viewfinder(run + [resolution])
                } else {
                    steps.append(.viewfinder([resolution]))
                }
            } else if id.hasPrefix("srtm") || id.hasPrefix("alos"), !credentialedPlaced {
                steps.append(.credentialed(credentialedSources))
                credentialedPlaced = true
            }
        }
        return steps
    }

    /// Fills the `.hgt` cache from every source the recipe names, in its order.
    func fetchElevationTiles(covering bbox: BBox) async throws {
        let steps = fetchSteps
        for (index, step) in steps.enumerated() {
            let last = index == steps.count - 1
            switch step {
            case .direct(let source):
                if let tiled = source as? any DEMTileSource {
                    try await fetchDEMTiles(tiled, covering: bbox, last: last)
                } else if let gedtm = source as? GEDTM30 {
                    try await fetchGEDTMTiles(gedtm, covering: bbox, last: last)
                }
            case .viewfinder(let resolutions):
                try await fetchViewfinderTiles(resolutions, covering: bbox, last: last)
            case .credentialed(let sources):
                try await fetchCredentialedTiles(sources, covering: bbox)
            }
        }
    }

    /// SRTM and ALOS, through pyhgtmap, then converted from the GeoTIFF they publish.
    private func fetchCredentialedTiles(_ sources: [String], covering bbox: BBox) async throws {
        guard let pyhgtmap = toolchain.findPyhgtmap()?.url else {
            throw BuildError.missingTool(
                "pyhgtmap — needed to download \(sources.joined(separator: ", "))."
                    + " Install it from the Toolchain screen, or choose copernicus, fabdem, gedtm or view1/view3"
            )
        }
        let runner = makeRunner()
        // --area is a rectangle; the same osmosis .poly the extract was cut with gives
        // pyhgtmap the trim the other fetchers compute. With no outline, the box stands.
        var scope = ["--area=\(bbox.areaArgument)"]
        if let clip = await writeElevationClipPolygon() {
            scope = ["--polygon=\(clip.nativePath)"]
        }
        try await runner.run(
            pyhgtmap.path,
            scope + [
                "--hgtdir=\(Paths.hgtCache.nativePath)",
                "--sources=\(sources.joined(separator: ","))",
                "--download-only"
            ],
            cwd: workDirectory
        ) { self.log.append($0) }

        elevationDownloadsFinished()
        elevationBuildStarted("converting")
        convertDownloadedGeoTIFF(covering: bbox, sources: sources)
    }
}
