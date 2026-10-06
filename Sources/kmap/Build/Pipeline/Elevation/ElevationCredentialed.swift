import Foundation

/// The two sources that still need an account, fetched through pyhgtmap and
/// converted from the GeoTIFF they publish.

extension BuildPipeline {
    /// Turns the GeoTIFF that SRTM and ALOS publish into the `.hgt` everything downstream
    /// reads. `--download-only` leaves pyhgtmap's files as `.tif`, and both the contour
    /// tracer and mkgmap's DEM read only directories holding `.hgt`.
    func convertDownloadedGeoTIFF(covering bbox: BBox, sources: [String]) {
        for source in sources {
            let directory = Paths.hgtCache.appendingPathComponent(
                source.uppercased(),
                isDirectory: true
            )
            guard FileTools.exists(directory) else { continue }
            // A cell a source listed earlier holds would never be read from here.
            let earlier = earlierSourceDirectories(before: source)
            // Cells convert independently and the shared mosaic is locked, so the
            // conversion spreads across every core.
            let wanted = elevationCells().filter { cell in
                let name = HGTName.of(lat: cell.lat, lon: cell.lon)
                return FileTools.exists(directory.appendingPathComponent("\(name).tif"))
                    && !FileTools.exists(directory.appendingPathComponent("\(name).hgt"))
                    && !cellSettledEarlier(earlier, lat: cell.lat, lon: cell.lon)
            }
            let nodes = Self.credentialedNodes(source)
            let mosaic = HGTConversion.Mosaic(converting: wanted) { lat, lon in
                let file = directory.appendingPathComponent(
                    "\(HGTName.of(lat: lat, lon: lon)).tif"
                )
                return FileTools.exists(file) ? file : nil
            }
            let made = Counter()
            let stop = stopAsked
            DispatchQueue.concurrentPerform(iterations: wanted.count) { index in
                // A stop lands between cells, as the task's cancellation does not reach here.
                if stop() { return }
                let cell = wanted[index]
                let name = HGTName.of(lat: cell.lat, lon: cell.lon)
                let destination = directory.appendingPathComponent("\(name).hgt")
                do {
                    try landHGT(cell, from: mosaic, to: destination, nodes: nodes)
                    made.increment()
                } catch {
                    log.warn("\(name): \(error)")
                    // A file of its own that will not read would fail every build after
                    // this one too: it goes, and is fetched again.
                    // Not one a minute old: another kmap's pyhgtmap writes it in place.
                    let tif = directory.appendingPathComponent("\(name).tif")
                    if let failure = mosaic.failure(lat: cell.lat, lon: cell.lon), GeoTIFF.Trouble.isDamage(failure),
                        let changed = FileTools.modified(of: tif), Date().timeIntervalSince(changed) > 60
                    {
                        FileTools.removeIfPresent(tif)
                        log.warn("\(name).tif would not read — it is fetched again on the next build")
                    }
                }
            }
            if made.value > 0 { log.ok("\(source): \(made.value) tile(s) converted to .hgt") }
        }
    }

    /// The grid side a pyhgtmap source is written at: its own spacing, 3 arc-seconds for
    /// `srtm3`, 1 for the rest.
    static func credentialedNodes(_ source: String) -> Int {
        source.hasSuffix("3") ? HGTConversion.arcSecondsPerDegree / 3 + 1 : HGTConversion.arcSecondsPerDegree + 1
    }
}
