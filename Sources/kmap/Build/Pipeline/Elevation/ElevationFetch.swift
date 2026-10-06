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
                try await fetchCredentialedTiles(sources, covering: bbox, last: last)
            }
        }
    }

    /// SRTM and ALOS, through pyhgtmap, then converted from the GeoTIFF they publish. Only
    /// the cells no earlier source holds are asked for, and a source with no working login,
    /// or a pyhgtmap that fails, leaves its cells to the sources listed after it.
    private func fetchCredentialedTiles(_ sources: [String], covering bbox: BBox, last: Bool) async throws {
        let reachable = Self.reachable(sources, usable: ElevationLogins.usable)
        if reachable.count < sources.count {
            let skipped = sources.filter { !reachable.contains($0) }.joined(separator: ", ")
            log.warn("\(skipped) skipped: no working login — the other sources fill its cells")
        }
        let earlier = sources.first.map { earlierSourceDirectories(before: $0) } ?? []
        let open = elevationCells().filter { !cellSettledEarlier(earlier, lat: $0.lat, lon: $0.lon) }
        let pyhgtmap = reachable.isEmpty || open.isEmpty ? nil : toolchain.findPyhgtmap()?.url
        if !reachable.isEmpty, !open.isEmpty, pyhgtmap == nil {
            let missing = BuildError.missingTool(
                "pyhgtmap — needed to download \(reachable.joined(separator: ", "))."
                    + " Install it from the Toolchain screen, or choose copernicus, fabdem, gedtm or view1/view3"
            )
            // Last in the list, nothing else is coming; earlier, the sources after it fill in.
            if last { throw missing }
            log.warn("\(missing.localizedDescription) — the sources after it fill its cells")
        }
        if let pyhgtmap {
            let runner = makeRunner()
            // --area is a rectangle; a .poly of the open cells asks for those tiles alone.
            var scope = ["--area=\(bbox.areaArgument)"]
            if let clip = writeOpenCellsPolygon(open) {
                scope = ["--polygon=\(clip.nativePath)"]
            }
            let ran = try await runner.run(
                pyhgtmap.path,
                scope + [
                    "--hgtdir=\(Paths.hgtCache.nativePath)",
                    "--sources=\(reachable.joined(separator: ","))",
                    "--download-only"
                ],
                cwd: workDirectory,
                allowFailure: true
            ) { self.log.append($0) }
            try Task.checkCancellation()
            if ran.exitCode != 0 {
                log.warn(
                    "pyhgtmap ended with code \(ran.exitCode) — what it fetched is used, the other sources"
                        + " fill the rest: \(ran.tail.suffix(3).joined(separator: " / "))"
                )
            }
        }

        if last { elevationDownloadsFinished() }
        elevationBuildStarted("converting")
        convertDownloadedGeoTIFF(covering: bbox, sources: sources)
        forgetDEMSearchPaths()
        if Self.endsWithNoTiles(last: last, onHand: mapHGTCount()) { throw BuildError.noElevationTiles }
    }

    /// Cells as few rectangles, in whole degrees, each bound inclusive: runs along a row,
    /// then a run stacked on the same run of the row below.
    static func openRectangles(_ cells: [(lat: Int, lon: Int)]) -> [(south: Int, north: Int, west: Int, east: Int)] {
        var runs: [Int: [(west: Int, east: Int)]] = [:]
        for (lat, row) in Dictionary(grouping: cells, by: \.lat) {
            var lons = Array(Set(row.map(\.lon))).sorted()
            var out: [(west: Int, east: Int)] = []
            while let first = lons.first {
                var east = first
                lons.removeFirst()
                while lons.first == east + 1 {
                    east += 1
                    lons.removeFirst()
                }
                out.append((first, east))
            }
            runs[lat] = out
        }
        var boxes: [(south: Int, north: Int, west: Int, east: Int)] = []
        for lat in runs.keys.sorted() {
            for run in runs[lat] ?? [] {
                if let at = boxes.firstIndex(where: {
                    $0.north == lat - 1 && $0.west == run.west && $0.east == run.east
                }) {
                    boxes[at].north = lat
                } else {
                    boxes.append((lat, lat, run.west, run.east))
                }
            }
        }
        return boxes
    }

    /// The sources whose login works; one that needs none is always reachable.
    static func reachable(_ sources: [String], usable: (ElevationLogins.Service) -> Bool) -> [String] {
        sources.filter { source in
            ElevationLogins.Service.allCases.first { $0.sourceIDs.contains(source) }.map(usable) ?? true
        }
    }

    /// The open cells as rectangles a shade inside their edges, so pyhgtmap does not take
    /// the tile across a shared edge as touched. Runs of cells along a row are joined, and
    /// equal runs in the rows above, as pyhgtmap tests every tile against every section.
    private func writeOpenCellsPolygon(_ cells: [(lat: Int, lon: Int)]) -> URL? {
        let inset = 0.01
        let sections = Self.openRectangles(cells).map { box -> [(lon: Double, lat: Double)] in
            let west = Double(box.west) + inset, east = Double(box.east + 1) - inset
            let south = Double(box.south) + inset, north = Double(box.north + 1) - inset
            return [(west, south), (east, south), (east, north), (west, north)]
        }
        let url = workDirectory.appendingPathComponent("elevation-clip.poly")
        do {
            try FileTools.write(RegionOutline.polyText(name: "kmap-elevation", sections: sections), to: url)
            return url
        } catch {
            log.warn("could not write the elevation cells polygon — using the box: \(error)")
            return nil
        }
    }
}
