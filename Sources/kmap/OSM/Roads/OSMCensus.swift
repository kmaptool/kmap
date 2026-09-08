import Foundation

/// Counts what the repair pass would have to hold, straight off a PBF.
///
/// Its whole job is to be checkable: the same file must yield the same figures on every
/// run and every platform, so a disagreement means the reader is wrong.
struct OSMCensus: OSMSink {
    /// The same set the annotate pass routes on.
    static let roadKinds: Set<String> = [
        "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
        "residential", "service", "track", "path", "footway", "cycleway", "bridleway",
        "living_street", "road", "steps", "motorway_link", "trunk_link", "primary_link",
        "secondary_link", "tertiary_link", "pedestrian", "construction",
    ]
    static let enclosing: Set<String> = ["fence", "wall", "hedge", "city_wall", "hedge_bank"]

    var nodes = 0
    var ways = 0
    var roads = 0
    var roadPoints = 0
    var obstacles = 0
    var obstaclePoints = 0
    /// Nodes and ways carrying addr:housenumber — what mkgmap's address search is
    /// built from. Numbers are search data, not labels drawn on the map.
    var addresses = 0

    mutating func node(id: Int64, lat: Double, lon: Double,
                       tags: ArraySlice<Int32>, block: OSMBlock) {
        nodes += 1
        var at = tags.startIndex
        while at + 1 < tags.endIndex {
            if block.text(Int(tags[at])) == "addr:housenumber" { addresses += 1; break }
            at += 2
        }
    }

    mutating func way(id: Int64, refs: ArraySlice<Int64>,
                      keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {
        ways += 1
        var highway: String?
        var barrier: String?
        var natural: String?
        var waterway: String?
        var manMade: String?
        var building = false
        var numbered = false
        for (i, key) in keys.enumerated() {
            guard i < values.count else { break }
            let value = values[values.startIndex + i]
            switch block.text(Int(key)) {
            case "highway": highway = block.text(Int(value))
            case "barrier": barrier = block.text(Int(value))
            case "natural": natural = block.text(Int(value))
            case "waterway": waterway = block.text(Int(value))
            case "man_made": manMade = block.text(Int(value))
            case "building": building = true
            case "addr:housenumber": numbered = true
            default: break
            }
        }
        if numbered { addresses += 1 }
        if let highway, Self.roadKinds.contains(highway) {
            roads += 1
            roadPoints += refs.count
            return
        }
        if Self.obstacleKind(barrier: barrier, natural: natural, waterway: waterway,
                             manMade: manMade, building: building) != nil {
            obstacles += 1
            obstaclePoints += refs.count
        }
    }

    /// The same ladder the loader walks, answering in the Python tool's words so the two
    /// censuses can be compared line for line. The ladder itself lives in one place.
    static func obstacleKind(barrier: String?, natural: String?, waterway: String?,
                             manMade: String?, building: Bool) -> String? {
        guard let kind = RoadNetworkLoader.obstacleKind(
            barrier: barrier, natural: natural, waterway: waterway,
            manMade: manMade, building: building) else { return nil }
        // The census reports the barrier's own word where the loader reports its class:
        // a kerb counts as a kerb here and as a crossable barrier there.
        if kind == .barrier, let barrier { return barrier }
        switch kind {
        case .fence: return "fence"
        case .building: return "building"
        case .cliff: return "cliff"
        case .ravine: return "ravine"
        case .water: return "water"
        case .embankment: return "embankment"
        case .barrier: return "barrier"
        }
    }
}
