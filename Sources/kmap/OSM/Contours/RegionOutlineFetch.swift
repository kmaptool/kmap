import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a module of its own outside Apple's platforms.
import FoundationNetworking
#endif

/// Where a region's outline comes from: the cache, or Geofabrik beside the extract.
extension RegionOutline {
    /// Geofabrik names the polygon after the extract.
    private static let extractSuffix = "-latest.osm.pbf"
    private static let polySuffix = ".poly"
    private static let polyTimeout: TimeInterval = 30

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
        var request = URLRequest(url: polyURL)
        request.timeoutInterval = polyTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              let rings = parse(text) else { return nil }
        try? data.write(to: file, options: .atomic)
        return rings
    }
}
