import Foundation

/// The two sources that still need an account, fetched through pyhgtmap and
/// converted from the GeoTIFF they publish.

extension BuildPipeline {
    /// Turns the GeoTIFF that SRTM and ALOS publish into the `.hgt` everything downstream
    /// reads. `--download-only` leaves pyhgtmap's files as `.tif`, and both the contour
    /// tracer and mkgmap's DEM read only directories holding `.hgt`.
    func convertDownloadedGeoTIFF(covering bbox: BBox, sources: [String]) {
        for source in sources {
            let directory = Paths.hgtCache.appendingPathComponent(source.uppercased(),
                                                                  isDirectory: true)
            guard FileTools.exists(directory) else { continue }
            let mosaic = HGTConversion.Mosaic { lat, lon in
                let file = directory.appendingPathComponent(
                    "\(CopernicusDEM.cellName(lat: lat, lon: lon)).tif")
                return FileTools.exists(file) ? file : nil
            }
            // Cells convert independently and the shared mosaic is locked, so the
            // conversion spreads across every core.
            let wanted = elevationCells().filter { cell in
                let name = CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon)
                return FileTools.exists(directory.appendingPathComponent("\(name).tif"))
                    && !FileTools.exists(directory.appendingPathComponent("\(name).hgt"))
            }
            let made = Counter()
            DispatchQueue.concurrentPerform(iterations: wanted.count) { index in
                let cell = wanted[index]
                let name = CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon)
                let destination = directory.appendingPathComponent("\(name).hgt")
                do {
                    try HGTConversion.write(cell: cell, from: mosaic, to: destination)
                    made.increment()
                } catch {
                    log.warn("\(name): \(error)")
                }
            }
            if made.value > 0 { log.ok("\(source): \(made.value) tile(s) converted to .hgt") }
        }
    }
}
