import Foundation

/// Every routable way and every obstacle in an extract, held as flat arrays.
///
/// Parallel `[Double]` and `[Int64]` rather than an object per way: a country-sized
/// extract holds tens of millions of points, where per-object overhead dominates.
struct RoadNetwork {
    /// Ways, as a run of point indices: way `i` owns `start[i] ..< start[i + 1]`.
    var wayID: [Int64] = []
    var start: [Int32] = [0]
    /// layer, bridge and tunnel folded into one number. Two ends only meet if they match.
    var level: [Int32] = []
    var refs: [Int64] = []
    var lat: [Double] = []
    var lon: [Double] = []

    var obstacleStart: [Int32] = [0]
    var obstacleKind: [UInt8] = []
    /// The obstacle's own word — "kerb", "retaining_wall" — as an index into `vocabulary`,
    /// and the name it carries on the map. Interned: many obstacles, few distinct words.
    var obstacleWord: [UInt8] = []
    var vocabulary: [String] = []
    /// Metres, or nan where OSM does not say.
    var obstacleHeight: [Float] = []
    var obstacleLat: [Double] = []
    var obstacleLon: [Double] = []

    var wayCount: Int { wayID.count }
    var obstacleCount: Int { obstacleKind.count }

    func points(of way: Int) -> Range<Int> {
        Int(start[way])..<Int(start[way + 1])
    }

    /// Which obstacle a point belongs to. Binary search over the run starts, so the grid
    /// can carry a bare point index and nothing wider.
    func obstacleOwning(point: Int) -> Int {
        var low = 0, high = obstacleStart.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if Int(obstacleStart[mid]) <= point { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func obstaclePoints(of obstacle: Int) -> Range<Int> {
        Int(obstacleStart[obstacle])..<Int(obstacleStart[obstacle + 1])
    }
}

/// What an obstacle is, in one byte. The raw values match `obstacle_kind()` in the
/// reference Python tool.
enum ObstacleKind: UInt8 {
    case fence = 0          // a plot boundary: never crossed, at any height
    case building = 1       // no route was meant to go through a house
    case cliff = 2
    case ravine = 3
    case water = 4          // river or canal; a stream is not an obstacle to a walker
    case embankment = 5
    case barrier = 6        // a kerb, a guard rail, a chain: crossable, and marked when crossed

    var isImpassable: Bool { self == .fence || self == .building }
}

/// Reads a PBF into a RoadNetwork.
///
/// Two passes: a PBF stores its nodes before the ways that use them, so which node
/// positions are wanted is not known until the ways have been read.
struct RoadNetworkLoader {
    let url: URL

    /// Ways on different decks do not meet, whatever the map looks like from above.
    static func level(layer: String, bridge: String, tunnel: String) -> Int32 {
        let deck = Int32(layer) ?? 0
        return deck * 4 + (bridge == "no" ? 0 : 1) * 2 + (tunnel == "no" ? 0 : 1)
    }

    /// The OSM values each class is recognised by. A barrier is anything else tagged
    /// `barrier=*`, which is how a value invented next week still counts as one.
    private static let cliffKinds: Set<String> = ["cliff", "arete"]
    private static let ravineKinds: Set<String> = ["gully", "gorge", "sinkhole"]
    private static let waterKinds: Set<String> = ["river", "canal"]
    private static let embankmentKinds: Set<String> = ["embankment", "pier", "breakwater"]

    static func obstacleKind(barrier: String?, natural: String?, waterway: String?,
                             manMade: String?, building: Bool) -> ObstacleKind? {
        if let barrier, OSMCensus.enclosing.contains(barrier) { return .fence }
        if barrier != nil { return .barrier }
        if let natural, cliffKinds.contains(natural) { return .cliff }
        if building { return .building }
        if let natural, ravineKinds.contains(natural) { return .ravine }
        if let waterway, waterKinds.contains(waterway) { return .water }
        if let manMade, embankmentKinds.contains(manMade) { return .embankment }
        return nil
    }

    func load() throws -> RoadNetwork {
        var shape = ShapeCollector()
        var vocabulary: [String: UInt8] = [:]
        try PBFReader(url: url).readInOrder(make: { ShapeCollector() }) { part in
            shape.network.wayID.append(contentsOf: part.network.wayID)
            shape.network.level.append(contentsOf: part.network.level)
            let refBase = Int32(shape.network.refs.count)
            shape.network.refs.append(contentsOf: part.network.refs)
            for start in part.network.start.dropFirst() {
                shape.network.start.append(refBase + start)
            }

            let obstacleBase = Int32(shape.obstacleRefs.count)
            shape.obstacleRefs.append(contentsOf: part.obstacleRefs)
            for start in part.network.obstacleStart.dropFirst() {
                shape.network.obstacleStart.append(obstacleBase + start)
            }
            shape.network.obstacleKind.append(contentsOf: part.network.obstacleKind)
            shape.network.obstacleHeight.append(contentsOf: part.network.obstacleHeight)
            for word in part.words {
                if let known = vocabulary[word] {
                    shape.network.obstacleWord.append(known)
                } else if shape.network.vocabulary.count < 255 {
                    let made = UInt8(shape.network.vocabulary.count)
                    shape.network.vocabulary.append(word)
                    vocabulary[word] = made
                    shape.network.obstacleWord.append(made)
                } else {
                    shape.network.obstacleWord.append(0)
                }
            }
            part.clear()
        }

        // Which node positions are actually wanted, once, in order.
        let unique = NodePlaces.wantedIDs(from: [shape.network.refs, shape.obstacleRefs])
        let places = try NodePlaces.gather(unique, from: url)

        // A way may name a node the extract does not contain, since the cut runs through
        // ways. Such points are dropped, and a way left with fewer than two goes with them.
        var network = RoadNetwork()
        network.vocabulary = shape.network.vocabulary
        network.wayID.reserveCapacity(shape.network.wayCount)
        for way in 0..<shape.network.wayCount {
            let range = shape.network.points(of: way)
            let first = network.refs.count
            for i in range {
                let ref = shape.network.refs[i]
                guard let point = places.place(of: ref) else { continue }
                network.refs.append(ref)
                network.lat.append(point.lat)
                network.lon.append(point.lon)
            }
            if network.refs.count - first >= 2 {
                network.wayID.append(shape.network.wayID[way])
                network.level.append(shape.network.level[way])
                network.start.append(Int32(network.refs.count))
            } else {
                network.refs.removeLast(network.refs.count - first)
                network.lat.removeLast(network.lat.count - first)
                network.lon.removeLast(network.lon.count - first)
            }
        }

        for obstacle in 0..<shape.network.obstacleCount {
            let range = shape.network.obstaclePoints(of: obstacle)
            let first = network.obstacleLat.count
            for i in range {
                let ref = shape.obstacleRefs[i]
                guard let point = places.place(of: ref) else { continue }
                network.obstacleLat.append(point.lat)
                network.obstacleLon.append(point.lon)
            }
            if network.obstacleLat.count - first >= 2 {
                network.obstacleKind.append(shape.network.obstacleKind[obstacle])
                network.obstacleWord.append(shape.network.obstacleWord[obstacle])
                network.obstacleHeight.append(shape.network.obstacleHeight[obstacle])
                network.obstacleStart.append(Int32(network.obstacleLat.count))
            } else {
                network.obstacleLat.removeLast(network.obstacleLat.count - first)
                network.obstacleLon.removeLast(network.obstacleLon.count - first)
            }
        }
        return network
    }

}

/// First pass: the ways, and the node ids they will need.
///
/// One instance per block, filled on whichever core is free. Obstacle words are interned
/// where the blocks are joined, since a vocabulary shared between workers would need a lock.
private struct ShapeCollector: OSMSink {
    let wantedParts: OSMParts = .ways

    var network = RoadNetwork()
    var obstacleRefs: [Int64] = []
    /// The spelling of each obstacle in this block, in the order they were collected.
    var words: [String] = []

    mutating func clear() {
        network = RoadNetwork()
        obstacleRefs.removeAll(keepingCapacity: true)
        words.removeAll(keepingCapacity: true)
    }

    mutating func way(id: Int64, refs: ArraySlice<Int64>,
                      keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {
        guard refs.count >= 2 else { return }
        var highway: String?, barrier: String?, natural: String?
        var waterway: String?, manMade: String?, building = false
        var layer = "0", bridge = "no", tunnel = "no", height: Float = .nan
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
            case "layer": layer = block.text(Int(value))
            case "bridge": bridge = block.text(Int(value))
            case "tunnel": tunnel = block.text(Int(value))
            case "height", "est_height":
                height = Float(block.text(Int(value)).split(separator: " ").first.map(String.init)?
                    .replacingOccurrences(of: ",", with: ".") ?? "") ?? .nan
            default: break
            }
        }

        if let highway, OSMCensus.roadKinds.contains(highway) {
            network.wayID.append(id)
            network.level.append(RoadNetworkLoader.level(layer: layer, bridge: bridge, tunnel: tunnel))
            network.refs.append(contentsOf: refs)
            network.start.append(Int32(network.refs.count))
            return
        }
        guard let kind = RoadNetworkLoader.obstacleKind(
            barrier: barrier, natural: natural, waterway: waterway,
            manMade: manMade, building: building) else { return }
        network.obstacleKind.append(kind.rawValue)
        network.obstacleWord.append(0)
        words.append(Self.word(for: kind, barrier: barrier, natural: natural,
                               waterway: waterway, manMade: manMade))
        network.obstacleHeight.append(height)
        obstacleRefs.append(contentsOf: refs)
        network.obstacleStart.append(Int32(obstacleRefs.count))
    }

    /// What an obstacle is called on the map: the OSM value it was recognised by.
    static func word(for kind: ObstacleKind, barrier: String?, natural: String?,
                     waterway: String?, manMade: String?) -> String {
        switch kind {
        case .fence, .barrier: return barrier ?? "barrier"
        case .cliff, .ravine: return natural ?? "cliff"
        case .water: return waterway ?? "water"
        case .embankment: return manMade ?? "embankment"
        case .building: return "building"
        }
    }

}

