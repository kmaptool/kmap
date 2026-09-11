import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a module of its own outside Apple's platforms.
import FoundationNetworking
#endif

/// One downloadable extract from Geofabrik's index.
struct Region {
    let id: String
    let name: String
    let parentID: String?
    let pbfURL: URL?
    /// The box around everything the region touches.
    let bbox: BBox
    /// The ground actually covered: one box per ring of the outline, so a region reaching
    /// across 180° yields two distant boxes rather than one spanning the globe. Anything
    /// counting ground -- elevation cells, the size estimate -- reads these.
    let boxes: [BBox]
    /// The outline itself, one ring of [lon, lat] vertices per entry in `boxes`. Boxes
    /// answer roughly where the region lies; the rings answer whether a given point is
    /// inside it.
    var rings: [[(lon: Double, lat: Double)]] = []
    var childIDs: [String] = []

    var hasChildren: Bool { !childIDs.isEmpty }

    /// Rough count of 1°×1° DEM tiles the region covers.
    var demTileCount: Int { boxes.reduce(0) { $0 + $1.demTileCount } }

    /// The slash-separated region path, used for cache filenames and output naming.
    var slug: String { id }

    /// The URL of the sibling `.md5` checksum file Geofabrik publishes.
    var md5URL: URL? {
        guard let pbfURL else { return nil }
        return URL(string: pbfURL.absoluteString + ".md5")
    }

    /// Whether the point lies inside the region's outline: even-odd ray casting over every
    /// ring, so an enclave ring subtracts itself. A region whose outline never parsed falls
    /// back to its boxes; a ring whose box misses the point cannot change parity, and is skipped.
    func holds(lat: Double, lon: Double) -> Bool {
        guard !rings.isEmpty else {
            return (boxes.isEmpty ? [bbox] : boxes)
                .contains { $0.contains(lat: lat, lon: lon) }
        }
        var inside = false
        for (at, ring) in rings.enumerated() where ring.count >= 3 {
            if at < boxes.count, !boxes[at].contains(lat: lat, lon: lon) { continue }
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[i], b = ring[j]
                if (a.lat > lat) != (b.lat > lat),
                   lon < (b.lon - a.lon) * (lat - a.lat) / (b.lat - a.lat) + a.lon {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
    }
}

/// The parsed Geofabrik region tree, cached on disk.
final class RegionIndex {
    private(set) var regions: [String: Region] = [:]
    private(set) var rootIDs: [String] = []

    private static let indexURL = URL(string: "https://download.geofabrik.de/index-v1.json")!
    /// Refetch the index if the cached copy is older than this.
    private static let maxCacheAge: TimeInterval = 7 * 24 * 3600

    enum LoadError: Error, LocalizedError {
        case network(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .network(let m): return t("Could not fetch the Geofabrik index: %@", m)
            case .malformed(let m):
                return t("Geofabrik index is not in the expected format: %@", m)
            }
        }
    }

    // MARK: Loading

    /// Returns cached JSON if it is fresh, otherwise downloads and caches it.
    private static func fetchIndexData(forceRefresh: Bool = false) async throws -> Data {
        Paths.bootstrap()
        let cached = Paths.indexCache
        if !forceRefresh,
           let attrs = try? FileManager.default.attributesOfItem(atPath: cached.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxCacheAge,
           let data = try? Data(contentsOf: cached), data.count > 1024 {
            return data
        }

        do {
            var request = URLRequest(url: indexURL)
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw LoadError.network("HTTP \(http.statusCode)")
            }
            // Cached only once it proves to be JSON: garbage written here would shadow
            // the stale copy the catch below falls back to, for a whole cache period.
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                try? data.write(to: cached, options: .atomic)
            }
            return data
        } catch {
            // Fall back to a stale cache rather than failing.
            if let data = try? Data(contentsOf: cached), data.count > 1024 { return data }
            throw LoadError.network(error.localizedDescription)
        }
    }

    func load(forceRefresh: Bool = false) async throws {
        let data = try await RegionIndex.fetchIndexData(forceRefresh: forceRefresh)
        // Parsed off the calling thread, installed on the main actor: the tables are read
        // from the main actor, and replacing a dictionary under a concurrent read is a race.
        let tables = try RegionIndex.tables(from: data)
        await MainActor.run {
            regions = tables.regions
            rootIDs = tables.roots
        }
    }

    // MARK: Parsing

    /// A region's name with the index's HTML removed: tags become a space, the common
    /// entities are decoded back to their characters, and runs of whitespace collapse.
    static func plainName(_ raw: String) -> String {
        var out = ""
        var insideTag = false
        for ch in raw {
            switch ch {
            case "<": insideTag = true
            case ">": insideTag = false; out.append(" ")
            default: if !insideTag { out.append(ch) }
            }
        }
        for (entity, character) in [("&amp;", "&"), ("&nbsp;", " "), ("&quot;", "\""),
                                    ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parse(_ data: Data) throws {
        let tables = try RegionIndex.tables(from: data)
        regions = tables.regions
        rootIDs = tables.roots
    }

    static func tables(from data: Data) throws -> (regions: [String: Region], roots: [String]) {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any],
              let features = dict["features"] as? [[String: Any]] else {
            throw LoadError.malformed("no features array")
        }

        var parsed: [String: Region] = [:]
        for feature in features {
            guard let props = feature["properties"] as? [String: Any],
                  let id = props["id"] as? String,
                  let rawName = props["name"] as? String else { continue }
            let name = RegionIndex.plainName(rawName)

            let parent = props["parent"] as? String
            var pbf: URL? = nil
            if let urls = props["urls"] as? [String: Any],
               let pbfString = urls["pbf"] as? String {
                pbf = URL(string: pbfString)
            }

            var boxes: [BBox] = []
            var rings: [[(lon: Double, lat: Double)]] = []
            if let geometry = feature["geometry"] as? [String: Any],
               let coords = geometry["coordinates"] {
                RegionIndex.walkRings(coords, into: &boxes, rings: &rings)
            }
            var box = BBox.empty
            for b in boxes {
                box.extend(lon: b.minLon, lat: b.minLat)
                box.extend(lon: b.maxLon, lat: b.maxLat)
            }

            parsed[id] = Region(id: id, name: name, parentID: parent,
                                pbfURL: pbf, bbox: box.isValid ? box : .empty,
                                boxes: boxes, rings: rings)
        }

        // Wire up children, then sort each list by display name.
        for (id, region) in parsed {
            guard let parentID = region.parentID, parsed[parentID] != nil else { continue }
            parsed[parentID]?.childIDs.append(id)
        }
        // Sorting reads names while the dictionary is being mutated, so snapshot them first.
        let names = parsed.mapValues(\.name)
        for id in parsed.keys where !(parsed[id]?.childIDs.isEmpty ?? true) {
            parsed[id]?.childIDs.sort { (names[$0] ?? $0) < (names[$1] ?? $1) }
        }

        let roots = parsed.values
            .filter { region in
                guard let parent = region.parentID else { return true }
                return parsed[parent] == nil
            }
            .sorted { $0.name < $1.name }
            .map(\.id)

        guard !parsed.isEmpty, !roots.isEmpty else {
            throw LoadError.malformed("parsed \(parsed.count) regions, \(roots.count) roots")
        }

        return (parsed, roots)
    }

    /// Descends GeoJSON coordinate nesting, which differs in depth between Polygon and
    /// MultiPolygon, to each ring of [lon, lat] pairs and takes a box around every ring
    /// separately: one box over all rings of a region crossing 180° would span the globe.
    private static func walkRings(_ node: Any, into boxes: inout [BBox],
                                  rings: inout [[(lon: Double, lat: Double)]]) {
        guard let array = node as? [Any], !array.isEmpty else { return }
        if point(array) != nil { return }
        if let first = array[0] as? [Any], point(first) != nil {
            var box = BBox.empty
            var ring: [(lon: Double, lat: Double)] = []
            ring.reserveCapacity(array.count)
            for element in array {
                guard let pair = element as? [Any], let p = point(pair) else { continue }
                box.extend(lon: p.lon, lat: p.lat)
                ring.append(p)
            }
            if box.isValid {
                boxes.append(box)
                rings.append(ring)
            }
            return
        }
        for child in array { walkRings(child, into: &boxes, rings: &rings) }
    }

    /// A [lon, lat] pair, however JSONSerialization happened to type it.
    private static func point(_ array: [Any]) -> (lon: Double, lat: Double)? {
        guard array.count >= 2, !(array[0] is NSArray) else { return nil }
        if let lon = array[0] as? Double, let lat = array[1] as? Double { return (lon, lat) }
        if let lon = array[0] as? NSNumber, let lat = array[1] as? NSNumber {
            return (lon.doubleValue, lat.doubleValue)
        }
        return nil
    }

    // MARK: Queries

    func region(_ id: String) -> Region? { regions[id] }

    /// True when `ancestor` is `id` itself or one of the regions above it.
    func isAncestor(_ ancestor: String, of id: String) -> Bool {
        var cursor: String? = id
        var hops = 0
        while let current = cursor, hops < 12 {
            if current == ancestor { return true }
            cursor = regions[current]?.parentID
            hops += 1
        }
        return false
    }

    func children(of id: String?) -> [Region] {
        let ids = id.flatMap { regions[$0]?.childIDs } ?? rootIDs
        return ids.compactMap { regions[$0] }
    }

    /// Human-readable path from the root down to the region, arrow-separated.
    func breadcrumb(_ id: String?) -> String {
        guard let id else { return "World" }
        var parts: [String] = []
        var cursor: String? = id
        var guardCount = 0
        while let current = cursor, let region = regions[current], guardCount < 16 {
            parts.append(region.name)
            cursor = region.parentID
            guardCount += 1
        }
        return (["World"] + parts.reversed()).joined(separator: " \(Glyph.arrowRight) ")
    }

    /// Case-insensitive substring search across every region, best matches first.
    func search(_ query: String, limit: Int = 300) -> [Region] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(Int, Region)] = []
        for region in regions.values {
            let name = region.name.lowercased()
            // The offset is measured in whichever string matched; an index taken from one
            // string is not valid in the other.
            var offset: Int
            if let range = name.range(of: q) {
                offset = name.distance(from: name.startIndex, to: range.lowerBound)
            } else {
                let id = region.id.lowercased()
                guard let range = id.range(of: q) else { continue }
                // The bias ranks an id hit behind every hit on a name.
                offset = id.distance(from: id.startIndex, to: range.lowerBound) + 20
            }
            // Prefer a prefix hit, then a shorter name, then a downloadable region.
            let score = offset * 100 + name.count + (region.pbfURL == nil ? 5000 : 0)
            scored.append((score, region))
        }
        return scored.sorted { $0.0 == $1.0 ? $0.1.name < $1.1.name : $0.0 < $1.0 }
            .prefix(limit)
            .map(\.1)
    }
}
