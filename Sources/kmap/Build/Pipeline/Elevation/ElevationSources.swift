import Foundation

/// Which elevation sources one build asked for, read from the recipe.

extension BuildPipeline {
    var usesCopernicus: Bool { !copernicusFlavors.isEmpty }

    /// The Copernicus resolutions this build asked for, in the order asked. Matched by
    /// whole id, never by prefix: "copernicus90" contains "copernicus" and a substring
    /// test would fetch both.
    var copernicusFlavors: [CopernicusDEM.Flavor] {
        demSourceList.compactMap { id in CopernicusDEM.flavors.first { $0.sourceID == id } }
    }

    /// The sources the recipe names, in the order it names them, which is the order they
    /// are tried in: the first to answer wins.
    var demSourceList: [String] {
        recipe.demSources.lowercased()
            .split(separator: ",")
            .map { CopernicusDEM.canonicalSourceID($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// Viewfinder resolutions asked for, in the order asked.
    var viewfinderResolutions: [Int] {
        demSourceList.compactMap { source in
            guard source.hasPrefix("view"), let resolution = Int(source.dropFirst(4)),
                  resolution == 1 || resolution == 3 else { return nil }
            return resolution
        }
    }

    /// The sources that still go through pyhgtmap: the two that need an account.
    var credentialedSources: [String] {
        demSourceList.filter { $0.hasPrefix("srtm") || $0.hasPrefix("alos") }
    }

    /// The `.hgt` directories of the sources listed before this one. A cell one of them
    /// already converted needs no coarser copy: the DEM and the contours take the first
    /// directory holding a cell, so a copy fetched anyway would never be read. This is
    /// what makes the source list a chain — `copernicus1,copernicus3` fetches GLO-30
    /// where it exists and GLO-90 only over its gaps.
    func earlierSourceDirectories(before source: String) -> [URL] {
        var out: [URL] = []
        for id in demSourceList {
            if id == source { break }
            if let flavor = CopernicusDEM.flavors.first(where: { $0.sourceID == id }) {
                out.append(flavor.cacheDirectory)
            } else if id.hasPrefix("view"), let resolution = Int(id.dropFirst(4)) {
                out.append(ViewfinderDEM.cacheDirectory(resolution))
            } else {
                // pyhgtmap names its directories after the source, upper-cased.
                out.append(Paths.hgtCache.appendingPathComponent(id.uppercased(),
                                                                 isDirectory: true))
            }
        }
        return out
    }

    /// Whether a source listed before this one already holds the cell.
    func cellSettledEarlier(_ directories: [URL], lat: Int, lon: Int) -> Bool {
        let name = "\(CopernicusDEM.cellName(lat: lat, lon: lon)).hgt"
        return directories.contains { FileTools.exists($0.appendingPathComponent(name)) }
    }
}
