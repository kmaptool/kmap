import Foundation

/// Where a region's outline comes from: the cache, or Geofabrik beside the extract.
extension RegionOutline {
    /// Geofabrik names the polygon after the extract.
    private static let extractSuffix = "-latest.osm.pbf"
    private static let polySuffix = ".poly"

    /// A region's `.poly`, from the cache or from beside its extract on Geofabrik. It is
    /// the exact polygon the extract was cut with, so anything trimmed to it agrees with
    /// the data.
    static func rings(for region: Region) async -> [Ring]? {
        Paths.ensure(Paths.polyCache)
        let file = Paths.polyCache.appendingPathComponent(FileTools.slugify(region.id) + polySuffix)
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let rings = parse(text) {
            return rings
        }
        guard let pbf = region.pbfURL,
              let polyURL = URL(string: pbf.absoluteString
                  .replacingOccurrences(of: extractSuffix, with: polySuffix)) else {
            return nil
        }
        guard let data = try? await Fetch.data(polyURL),
              let text = String(data: data, encoding: .utf8),
              let rings = parse(text) else { return nil }
        try? data.write(to: file, options: .atomic)
        return rings
    }
}
