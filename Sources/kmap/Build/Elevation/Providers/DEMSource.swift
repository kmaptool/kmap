import Foundation

/// An elevation source kmap reads itself and keeps as `.hgt`, a directory per source.
protocol DEMSource: Sendable {
    /// The source id shown in the build screen and stored in settings.
    var sourceID: String { get }
    /// Cache directory under hgt/. The 1 or 3 in the name is load-bearing: the DEM
    /// layer's finest-source-wins ordering reads it, as does the dem-dists choice.
    var directoryName: String { get }
    /// Nodes per `.hgt` side: 3601 for 1 arc-second, 1201 for 3.
    var nodes: Int { get }
    /// The name the build log uses.
    var label: String { get }
    /// The lines the map carries where the licence asks to be credited.
    var credits: [String] { get }
}

extension DEMSource {
    var credits: [String] { [] }

    var cacheDirectory: URL {
        Paths.hgtCache.appendingPathComponent(directoryName, isDirectory: true)
    }

    func cachedTile(lat: Int, lon: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).hgt")
    }
}
