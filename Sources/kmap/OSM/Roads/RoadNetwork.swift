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

    /// The fewest points a way or an obstacle has to keep to be a line at all.
    static let leastPoints = 2

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
    case fence = 0  // a plot boundary: never crossed, at any height
    case building = 1  // no route was meant to go through a house
    case cliff = 2
    case ravine = 3
    case water = 4  // river or canal; a stream is not an obstacle to a walker
    case embankment = 5
    case barrier = 6  // a kerb, a guard rail, a chain: crossable, and marked when crossed

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
        // Clamped: layer is free text, and a junk value must not overflow the arithmetic.
        let deck = min(max(Int32(layer) ?? 0, -furthestLayer), furthestLayer)
        return deck * levelsPerDeck + (bridge == "no" ? 0 : bridgeLevel) + (tunnel == "no" ? 0 : tunnelLevel)
    }

    /// The layer numbers kept apart; any further from the ground count as this far.
    private static let furthestLayer: Int32 = 1000
    /// A level is the deck and 2 flags in its low bits: on a bridge, in a tunnel.
    private static let levelsPerDeck: Int32 = 4
    private static let bridgeLevel: Int32 = 2
    private static let tunnelLevel: Int32 = 1

    /// The OSM values each class is recognised by. A barrier is anything else tagged
    /// `barrier=*`, which is how a value invented next week still counts as one.
    private static let cliffKinds: Set<String> = ["cliff", "arete"]
    private static let ravineKinds: Set<String> = ["gully", "gorge", "sinkhole"]
    private static let waterKinds: Set<String> = ["river", "canal"]
    private static let embankmentKinds: Set<String> = ["embankment", "pier", "breakwater"]

    static func obstacleKind(
        barrier: String?,
        natural: String?,
        waterway: String?,
        manMade: String?,
        building: Bool
    ) -> ObstacleKind? {
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
        let shape = try collectShapes()
        // Which node positions are actually wanted, once, in order.
        let unique = NodePlaces.wantedIDs(from: [shape.network.refs, shape.obstacleRefs])
        let places = try NodePlaces.gather(unique, from: url)

        // A way may name a node the extract does not contain, since the cut runs through
        // ways. Such points are dropped, and a way left too short goes with them.
        var network = RoadNetwork()
        network.vocabulary = shape.network.vocabulary
        Self.placeWays(of: shape, at: places, into: &network)
        Self.placeObstacles(of: shape, at: places, into: &network)
        return network
    }

    /// The first pass: every road and obstacle, by node id, the blocks joined in order.
    private func collectShapes() throws -> ShapeCollector {
        var shape = ShapeCollector()
        var vocabulary: [String: UInt8] = [:]
        try PBFReader(url: url).readInOrder(make: { ShapeCollector() }) { part in
            shape.absorb(part, vocabulary: &vocabulary)
            part.clear()
        }
        return shape
    }

    /// The roads, with the points the extract carries.
    private static func placeWays(of shape: ShapeCollector, at places: NodePlaces, into network: inout RoadNetwork) {
        network.wayID.reserveCapacity(shape.network.wayCount)
        // Sized for every point and cut to the points kept.
        let count = shape.network.refs.count
        var refs = [Int64](repeating: 0, count: count)
        var lat = [Double](repeating: 0, count: count)
        var lon = [Double](repeating: 0, count: count)
        let points = refs.withUnsafeMutableBufferPointer { refs in
            lat.withUnsafeMutableBufferPointer { lat in
                lon.withUnsafeMutableBufferPointer { lon in
                    let into = Kept(lat: lat, lon: lon, refs: refs)
                    return compact(shape.network.refs, runs: shape.network.start, in: places, into: into) { way, end in
                        network.wayID.append(shape.network.wayID[way])
                        network.level.append(shape.network.level[way])
                        network.start.append(Int32(end))
                    }
                }
            }
        }
        refs.removeLast(count - points)
        lat.removeLast(count - points)
        lon.removeLast(count - points)
        network.refs = refs
        network.lat = lat
        network.lon = lon
    }

    /// The obstacles, with the points the extract carries.
    private static func placeObstacles(
        of shape: ShapeCollector,
        at places: NodePlaces,
        into network: inout RoadNetwork
    ) {
        let count = shape.obstacleRefs.count
        var lat = [Double](repeating: 0, count: count)
        var lon = [Double](repeating: 0, count: count)
        let points = lat.withUnsafeMutableBufferPointer { lat in
            lon.withUnsafeMutableBufferPointer { lon in
                let into = Kept(lat: lat, lon: lon, refs: nil)
                return compact(shape.obstacleRefs, runs: shape.network.obstacleStart, in: places, into: into) {
                    obstacle,
                    end in
                    network.obstacleKind.append(shape.network.obstacleKind[obstacle])
                    network.obstacleWord.append(shape.network.obstacleWord[obstacle])
                    network.obstacleHeight.append(shape.network.obstacleHeight[obstacle])
                    network.obstacleStart.append(Int32(end))
                }
            }
        }
        lat.removeLast(count - points)
        lon.removeLast(count - points)
        network.obstacleLat = lat
        network.obstacleLon = lon
    }

    /// Where `compact` copies the points it keeps: their places, and for a way its node ids
    /// too. Each run is copied by 1 lane into its own stretch, so it needs no lock.
    private struct Kept: @unchecked Sendable {
        let lat: UnsafeMutableBufferPointer<Double>
        let lon: UnsafeMutableBufferPointer<Double>
        let refs: UnsafeMutableBufferPointer<Int64>?
    }

    /// Points looked up per stretch: whole runs at a time, so the slots held stay small
    /// beside the refs themselves.
    private static let pointsPerStretch = 1 << 22
    /// Runs handed to a core at a time.
    private static let runsPerLane = 1 << 12

    /// Keeps, of each run of `refs`, the points `places` holds, and the run itself only
    /// where enough remain: the extract's cut leaves some ways short. A stretch of runs at
    /// a time, the points are looked up, counted and copied across the cores. `kept` is
    /// told in order of each run kept and where its points end. `runs` holds the starts
    /// and the end, as `RoadNetwork.start` does. Returns how many points were kept.
    private static func compact(
        _ refs: [Int64],
        runs: [Int32],
        in places: NodePlaces,
        into out: Kept,
        kept: (Int, Int) -> Void
    ) -> Int {
        var slots = [Int64](repeating: -1, count: min(refs.count, pointsPerStretch))
        var total = 0
        var run = 0
        while run < runs.count - 1 {
            let stretch = run..<stretchEnd(from: run, runs: runs)
            let points = Int(runs[stretch.lowerBound])..<Int(runs[stretch.upperBound])
            if points.count > slots.count { slots = [Int64](repeating: -1, count: points.count) }
            lookUp(refs, points, in: places, into: &slots)
            var targets = countKept(runs: runs, stretch, slots: slots)
            for one in targets.indices {
                targets[one] = place(targets[one], total: &total)
                if targets[one] >= 0 { kept(stretch.lowerBound + one, total) }
            }
            copyKept(Stretch(runs: runs, range: stretch, slots: slots, targets: targets), refs, places, into: out)
            run = stretch.upperBound
        }
        return total
    }

    /// 1 stretch of runs as `compact` has it: the runs' slots, from the stretch's first
    /// point, and where each kept run's points go, -1 for a run dropped.
    private struct Stretch {
        let runs: [Int32]
        let range: Range<Int>
        let slots: [Int64]
        let targets: [Int]
    }

    /// Where the stretch starting at `run` ends: as many whole runs as fit the stretch,
    /// and at least 1.
    private static func stretchEnd(from run: Int, runs: [Int32]) -> Int {
        let count = runs.count - 1
        let from = Int(runs[run])
        var last = run + 1
        while last < count, Int(runs[last + 1]) - from <= pointsPerStretch { last += 1 }
        return last
    }

    private static func lookUp(_ refs: [Int64], _ points: Range<Int>, in places: NodePlaces, into slots: inout [Int64])
    {
        refs.withUnsafeBufferPointer { all in
            slots.withUnsafeMutableBufferPointer { out in
                guard let into = out.baseAddress, !points.isEmpty else { return }
                places.slots(of: UnsafeBufferPointer(rebasing: all[points]), into: into)
            }
        }
    }

    /// Where a run keeping `points` starts in the output, the total moved past it; -1 for
    /// a run too short to keep.
    private static func place(_ points: Int, total: inout Int) -> Int {
        guard points >= RoadNetwork.leastPoints else { return -1 }
        defer { total += points }
        return total
    }

    /// A run's slots, out of a stretch's that start at the stretch's first point.
    @inline(__always)
    private static func slots(
        of run: Int,
        runs: UnsafeBufferPointer<Int32>,
        in slots: UnsafeBufferPointer<Int64>,
        from base: Int
    ) -> UnsafeBufferPointer<Int64> {
        UnsafeBufferPointer(rebasing: slots[Int(runs[run]) - base..<Int(runs[run + 1]) - base])
    }

    /// How many points each run of the stretch keeps, counted across the cores.
    private static func countKept(runs: [Int32], _ stretch: Range<Int>, slots: [Int64]) -> [Int] {
        var counts = [Int](repeating: 0, count: stretch.count)
        let base = Int(runs[stretch.lowerBound])
        runs.withUnsafeBufferPointer { runs in
            slots.withUnsafeBufferPointer { slots in
                counts.withUnsafeMutableBufferPointer { counts in
                    // Each lane counts its own runs.
                    nonisolated(unsafe) let runs = runs, slots = slots, counts = counts
                    acrossLanes(stretch.count) { one in
                        let points = Self.slots(of: stretch.lowerBound + one, runs: runs, in: slots, from: base)
                        counts[one] = points.reduce(0) { $1 >= 0 ? $0 + 1 : $0 }
                    }
                }
            }
        }
        return counts
    }

    /// Copies every kept run of the stretch, across the cores.
    private static func copyKept(_ stretch: Stretch, _ refs: [Int64], _ places: NodePlaces, into out: Kept) {
        let base = Int(stretch.runs[stretch.range.lowerBound])
        let first = stretch.range.lowerBound, targets = stretch.targets
        refs.withUnsafeBufferPointer { refs in
            places.lat.withUnsafeBufferPointer { lat in
                places.lon.withUnsafeBufferPointer { lon in
                    stretch.runs.withUnsafeBufferPointer { runs in
                        stretch.slots.withUnsafeBufferPointer { slots in
                            // Each lane copies its own runs; the tables are only read.
                            nonisolated(unsafe) let refs = refs, lat = lat, lon = lon, runs = runs, slots = slots
                            acrossLanes(stretch.range.count) { one in
                                guard targets[one] >= 0 else { return }
                                let run = first + one
                                let points = Self.slots(of: run, runs: runs, in: slots, from: base)
                                var at = targets[one]
                                for i in 0..<points.count where points[i] >= 0 {
                                    let slot = Int(points[i])
                                    out.lat[at] = lat[slot]
                                    out.lon[at] = lon[slot]
                                    out.refs?[at] = refs[Int(runs[run]) + i]
                                    at += 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Runs `body` for each of `count` items, `runsPerLane` to a core at a time.
    private static func acrossLanes(_ count: Int, _ body: @Sendable (Int) -> Void) {
        DispatchQueue.concurrentPerform(iterations: (count + runsPerLane - 1) / runsPerLane) { lane in
            for one in lane * runsPerLane..<min(count, (lane + 1) * runsPerLane) { body(one) }
        }
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

    /// Obstacle words fit a byte; past this many, the rest are filed under the first.
    private static let mostWords = 255

    mutating func clear() {
        network = RoadNetwork()
        obstacleRefs.removeAll(keepingCapacity: true)
        words.removeAll(keepingCapacity: true)
    }

    /// Appends another block's collection after this one's, its words interned here.
    mutating func absorb(_ part: ShapeCollector, vocabulary: inout [String: UInt8]) {
        network.wayID.append(contentsOf: part.network.wayID)
        network.level.append(contentsOf: part.network.level)
        let refBase = Int32(network.refs.count)
        network.refs.append(contentsOf: part.network.refs)
        for start in part.network.start.dropFirst() { network.start.append(refBase + start) }

        let obstacleBase = Int32(obstacleRefs.count)
        obstacleRefs.append(contentsOf: part.obstacleRefs)
        for start in part.network.obstacleStart.dropFirst() {
            network.obstacleStart.append(obstacleBase + start)
        }
        network.obstacleKind.append(contentsOf: part.network.obstacleKind)
        network.obstacleHeight.append(contentsOf: part.network.obstacleHeight)
        for word in part.words { network.obstacleWord.append(intern(word, vocabulary: &vocabulary)) }
    }

    private mutating func intern(_ word: String, vocabulary: inout [String: UInt8]) -> UInt8 {
        if let known = vocabulary[word] { return known }
        guard network.vocabulary.count < Self.mostWords else { return 0 }
        let made = UInt8(network.vocabulary.count)
        network.vocabulary.append(word)
        vocabulary[word] = made
        return made
    }

    mutating func way(
        id: Int64,
        refs: ArraySlice<Int64>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        guard refs.count >= RoadNetwork.leastPoints else { return }
        let tags = WayTags(keys: keys, values: values, block: block)
        if let highway = tags.highway, OSMCensus.roadKinds.contains(highway) {
            network.wayID.append(id)
            network.level.append(RoadNetworkLoader.level(layer: tags.layer, bridge: tags.bridge, tunnel: tags.tunnel))
            network.refs.append(contentsOf: refs)
            network.start.append(Int32(network.refs.count))
            return
        }
        guard let kind = tags.obstacleKind else { return }
        network.obstacleKind.append(kind.rawValue)
        network.obstacleWord.append(0)
        words.append(tags.word(for: kind))
        network.obstacleHeight.append(tags.height)
        obstacleRefs.append(contentsOf: refs)
        network.obstacleStart.append(Int32(obstacleRefs.count))
    }
}

/// The tags of a way that make it a road or an obstacle.
private struct WayTags {
    var highway: String?, barrier: String?, natural: String?
    var waterway: String?, manMade: String?, building = false
    var layer = "0", bridge = "no", tunnel = "no", height: Float = .nan

    @inline(__always)
    init(keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {
        for (i, key) in keys.enumerated() {
            guard i < values.count else { break }
            // The value's text only for a key that is kept: most are not.
            let value = Int(values[values.startIndex + i])
            switch block.text(Int(key)) {
            case "highway": highway = block.text(value)
            case "barrier": barrier = block.text(value)
            case "natural": natural = block.text(value)
            case "waterway": waterway = block.text(value)
            case "man_made": manMade = block.text(value)
            case "building": building = true
            case "layer": layer = block.text(value)
            case "bridge": bridge = block.text(value)
            case "tunnel": tunnel = block.text(value)
            case "height", "est_height": height = Self.metres(block.text(value))
            default: break
            }
        }
    }

    /// A height as OSM writes one: a number, maybe with a decimal comma and a unit after.
    static func metres(_ text: String) -> Float {
        Float(text.split(separator: " ").first.map(String.init)?.replacingOccurrences(of: ",", with: ".") ?? "")
            ?? .nan
    }

    var obstacleKind: ObstacleKind? {
        RoadNetworkLoader.obstacleKind(
            barrier: barrier,
            natural: natural,
            waterway: waterway,
            manMade: manMade,
            building: building
        )
    }

    /// What an obstacle is called on the map: the OSM value it was recognised by.
    func word(for kind: ObstacleKind) -> String {
        switch kind {
        case .fence, .barrier: return barrier ?? "barrier"
        case .cliff, .ravine: return natural ?? "cliff"
        case .water: return waterway ?? "water"
        case .embankment: return manMade ?? "embankment"
        case .building: return "building"
        }
    }
}
