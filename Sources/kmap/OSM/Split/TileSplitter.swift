import Foundation

/// Splits one OSM extract into map tiles. An object inside one tile
/// and no other goes only there; a way or relation touching several is written complete to
/// each, and a multipolygon also to every tile its rings enclose. Areas are in Garmin map
/// units, degrees times 2^24 over 360, aligned to 2048 of them.
final class TileSplitter {

    /// One tile area, in map units, half-open on its top edges.
    struct Area {
        var minLat: Int32
        var minLon: Int32
        var maxLat: Int32
        var maxLon: Int32

        /// Converts the degrees a finished tile reports back to map units. The round trip
        /// is exact: both directions scale by the same power of two.
        init(bbox: BBox) {
            self.init(minLat: TileSplitter.mapUnits(bbox.minLat),
                      minLon: TileSplitter.mapUnits(bbox.minLon),
                      maxLat: TileSplitter.mapUnits(bbox.maxLat),
                      maxLon: TileSplitter.mapUnits(bbox.maxLon))
        }

        init(minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32) {
            self.minLat = minLat; self.minLon = minLon
            self.maxLat = maxLat; self.maxLon = maxLon
        }

        func contains(lat: Int32, lon: Int32) -> Bool {
            lat >= minLat && lat < maxLat && lon >= minLon && lon < maxLon
        }

        /// The same rectangle with a margin all round: the ground a tile may paint beyond
        /// its own frame, and so the ground it has to be given.
        func grown(by margin: Int32) -> Area {
            Area(minLat: minLat - margin, minLon: minLon - margin,
                 maxLat: maxLat + margin, maxLon: maxLon + margin)
        }
    }

    struct Options {
        /// Input files, read in the order given.
        var inputs: [URL]
        var outputDirectory: URL
        var mapID: Int
        var maxNodes: Int
        /// Fewest tiles the caller wants, whatever `maxNodes` allows; mkgmap compiles one
        /// tile per core. Ignored when it would push tiles below `leastNodesPerTile`.
        var leastTiles: Int = 1
        /// The floor under `leastTiles`. Below this a tile stops paying for itself:
        /// mkgmap's per-tile cost shows, and every extra border duplicates ways crossing it.
        var leastNodesPerTile: Int = 500_000
        var description: String
        /// Areas to distribute into. Nil means compute them from the node density.
        var areas: [Area]?
        /// How far past its own frame a tile may paint a shape, and so how wide a band of
        /// neighbouring ground it is given. Zero on a stock mkgmap, which cannot be told to
        /// draw past the frame at all. See `shapeClipOverlap`.
        var shapeOverlap: Int32 = TileSplitter.shapeClipOverlap
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case empty
        case tooManyAreas(Int)

        var description: String {
            switch self {
            case .empty: "the extract holds no nodes"
            case .tooManyAreas(let n): "the split needs \(n) tiles, which is past every limit"
            }
        }
    }

    // Not private: the split's passes live in files of their own, and Swift's `private`
    // is one file.
    let options: Options
    let log: (String) -> Void
    /// Told how far the split has come, 0...1, at each phase boundary. Reporting only —
    /// nothing inside the passes slows for it.
    var progress: ((Double) -> Void)?
    /// Nodes seen while measuring density, which is what sizes the node table. Zero when
    /// the areas were given and the measuring was skipped.
    private var countedNodes = 0

    init(options: Options, log: @escaping (String) -> Void) {
        self.options = options
        self.log = log
    }

    // MARK: Units

    /// Converts degrees to Garmin map units, rounding as Java's Math.round does, floor of
    /// x plus a half, which is what splitter did.
    static func mapUnits(_ degrees: Double) -> Int32 {
        // Clamping, not trapping: a corrupt coordinate must miscount a node rather than
        // kill the split.
        let units = (degrees * Double(1 << 24) / 360.0 + 0.5).rounded(.down)
        if units >= Double(Int32.max) { return Int32.max }
        if units <= Double(Int32.min) { return Int32.min }
        return Int32(units)
    }

    static func degrees(_ units: Int32) -> Double {
        Double(units) * 360.0 / Double(1 << 24)
    }

    /// The alignment grid: 2048 map units, resolution 13.
    static let grain: Int32 = 2048
    /// The same grain as a shift and a mask.
    static let gridShift: Int32 = 11
    static let gridMask: Int32 = grain - 1

    /// How far past its own frame a tile may paint a polygon, in map units, about 4.8 km.
    /// The compiler is given this as `--x-shape-clip-overlap` and delivery widens the tiles
    /// by the same amount; the two must agree, or a tile paints a band it holds no data
    /// for and buries what the neighbour drew.
    static let shapeClipOverlap: Int32 = 2048

    /// How far past its own frame a tile may paint the land layer, in map units, about
    /// 600 m. Land stopping exactly on the frame leaves a hairline where a receiver clips
    /// a tile to its declared bounds; land drawn far past it covers what the neighbour
    /// drew. Needs no matching delivery: mkgmap generates the land polygons per tile.
    static let landClipOverlap: Int32 = 640

    // MARK: The run

    struct Result {
        var tiles: [(mapID: String, area: Area, nodes: Int)]
        var areasList: URL
        var templateArgs: URL
    }

    func run() throws -> Result {
        var mark = Date()
        func took(_ what: String) {
            if let line = Measured.line(what, since: mark) { log(line) }
            mark = Date()
        }

        let areas: [Area]
        if let given = options.areas {
            // A re-split's halves are cut on the grid, where a power of two can sit; the
            // nudge is idempotent elsewhere, so a given list takes it too.
            areas = TileSplitter.nudgedOffPowersOfTwo(given)
        } else {
            areas = TileSplitter.nudgedOffPowersOfTwo(try computeAreas())
            took("measured where the nodes are")
        }
        log("\(areas.count) tile area(s)")
        progress?(0.2)

        let lookup = AreaLookup(areas: areas, shapeOverlap: options.shapeOverlap)
        let assignment = try assignNodes(lookup: lookup)
        took("placed every node")
        progress?(0.6)
        let plan = try planProblems(assignment: assignment, lookup: lookup, areas: areas)
        took("worked out what spans tiles")
        progress?(0.75)
        let counts = try write(areas: areas, assignment: assignment, plan: plan)
        took("wrote the tiles")
        progress?(1)

        let listURL = options.outputDirectory.appendingPathComponent("areas.list")
        let argsURL = options.outputDirectory.appendingPathComponent("template.args")
        var tiles: [(mapID: String, area: Area, nodes: Int)] = []
        for (index, area) in areas.enumerated() {
            tiles.append((mapID: String(options.mapID + index), area: area,
                          nodes: counts[index]))
        }
        try writeAreasList(tiles, to: listURL)
        try writeTemplateArgs(tiles, to: argsURL)
        return Result(tiles: tiles, areasList: listURL, templateArgs: argsURL)
    }

    // MARK: Deciding the areas

    /// Moves interior tile boundaries off very round coordinates. On a boundary with more
    /// than 13 trailing zero bits both neighbours place a subdivision edge at the same
    /// coordinate at every zoom and a receiver draws the join as a line. Only boundaries
    /// shared by two areas move, as one value, so the areas still partition the ground.
    static func nudgedOffPowersOfTwo(_ areas: [Area]) -> [Area] {
        guard areas.count > 1 else { return areas }

        func tooRound(_ v: Int32) -> Bool {
            v != 0 && v % (1 << 16) == 0
        }
        func interior(_ pick: (Area) -> (Int32, Int32)) -> Set<Int32> {
            var lows: Set<Int32> = [], highs: Set<Int32> = []
            for area in areas {
                let (low, high) = pick(area)
                lows.insert(low); highs.insert(high)
            }
            return lows.intersection(highs).filter(tooRound)
        }
        let lats = interior { ($0.minLat, $0.maxLat) }
        let lons = interior { ($0.minLon, $0.maxLon) }
        guard !lats.isEmpty || !lons.isEmpty else { return areas }

        // One grid cell, so the boundary stays on the grid the whole split lives on.
        func moved(_ v: Int32, _ set: Set<Int32>) -> Int32 {
            set.contains(v) ? v + TileSplitter.grain : v
        }
        return areas.map {
            Area(minLat: moved($0.minLat, lats), minLon: moved($0.minLon, lons),
                 maxLat: moved($0.maxLat, lats), maxLon: moved($0.maxLon, lons))
        }
    }

    static func refined(_ areas: [Area], splitting failed: Set<Int>) -> [Area] {
        var out: [Area] = []
        for (index, area) in areas.enumerated() {
            guard failed.contains(index) else {
                out.append(area)
                continue
            }
            let tall = (area.maxLat - area.minLat) >= (area.maxLon - area.minLon)
            let low = tall ? area.minLat : area.minLon
            let high = tall ? area.maxLat : area.maxLon
            // The midpoint, held to the alignment grid. A cut that cannot leave both
            // halves at least one cell wide leaves the area alone.
            let cut = ((low + (high - low) / 2) >> TileSplitter.gridShift) << TileSplitter.gridShift
            guard cut > low, cut < high else {
                out.append(area)
                continue
            }
            if tall {
                out.append(Area(minLat: area.minLat, minLon: area.minLon,
                                maxLat: cut, maxLon: area.maxLon))
                out.append(Area(minLat: cut, minLon: area.minLon,
                                maxLat: area.maxLat, maxLon: area.maxLon))
            } else {
                out.append(Area(minLat: area.minLat, minLon: area.minLon,
                                maxLat: area.maxLat, maxLon: cut))
                out.append(Area(minLat: area.minLat, minLon: cut,
                                maxLat: area.maxLat, maxLon: area.maxLon))
            }
        }
        return out
    }

    /// Nodes a tile may hold. `maxNodes` keeps a tile inside Garmin's 16 MB drawing
    /// section; the node count divided by `leastTiles` competes with it, and the smaller
    /// of the two wins.
    func nodeCap(for nodes: Int) -> Int {
        guard options.leastTiles > 1 else { return options.maxNodes }
        let spread = (nodes + options.leastTiles - 1) / options.leastTiles
        return min(options.maxNodes, max(options.leastNodesPerTile, spread))
    }

    /// Counts nodes on the alignment grid and cuts the map into grid-aligned areas, none
    /// over the node cap, together covering every node. Each cut runs along the longer
    /// axis at the weighted median.
    private func computeAreas() throws -> [Area] {
        var density = Density()
        // The header's bounding box is the map: areas are cut inside it and the fringe
        // beyond it is not counted. One window per input, and a node is kept if it falls
        // inside any of them.
        for input in options.inputs {
            guard let bbox = try PBFReader(url: input).headerBBox() else { continue }
            density.clips.append((minLatCell: Self.mapUnits(bbox.minLat) >> TileSplitter.gridShift,
                                  minLonCell: Self.mapUnits(bbox.minLon) >> TileSplitter.gridShift,
                                  maxLatCell: (Self.mapUnits(bbox.maxLat) + TileSplitter.gridMask) >> TileSplitter.gridShift,
                                  maxLonCell: (Self.mapUnits(bbox.maxLon) + TileSplitter.gridMask) >> TileSplitter.gridShift))
            log(String(format: "covers %.4f..%.4f / %.4f..%.4f",
                       bbox.minLat, bbox.maxLat, bbox.minLon, bbox.maxLon))
        }
        density.prepare()
        for input in options.inputs {
            let clips = density.clips
            for part in try PBFReader(url: input).readConcurrently(make: {
                var sink = Density()
                sink.clips = clips
                sink.prepare()
                return sink
            }) {
                density.merge(part)
            }
        }
        guard density.total > 0 else { throw Trouble.empty }
        // Fringe nodes, outside every window, go uncounted, so this is a lower
        // bound on the file's node count.
        countedNodes = density.total
        density.seal()

        let cap = nodeCap(for: density.total)
        var out: [Area] = []
        // How many tiles a rectangle needs decides where it is cut: taking floor(needed/2)
        // shares at a time lands on the fewest tiles.
        var queue: [(Density.Cells, Int)] = []
        let total = density.count(density.boundsCells())
        queue.append((density.boundsCells(), max(1, (total + cap - 1) / cap)))
        while let (rect, needed) = queue.popLast() {
            let count = density.count(rect)
            if count == 0 { continue }
            // Empty ground first, before any question of size: one rectangle over two
            // far-apart regions would claim all the ground between them, which the map
            // then declares it covers. Cutting through the gap gives one area per region.
            if let (a, b) = density.splitAcrossGap(rect) {
                let countA = density.count(a)
                queue.append((a, max(1, (countA + cap - 1) / cap)))
                queue.append((b, max(1, (count - countA + cap - 1) / cap)))
                continue
            }
            if needed <= 1 || count <= cap {
                out.append(rect.area)
                continue
            }
            guard out.count + queue.count < 4096 else { throw Trouble.tooManyAreas(out.count) }
            let leftShare = needed / 2
            guard let (a, b) = density.split(rect, share: Double(leftShare) / Double(needed))
            else {
                // One grid cell holds more than the cap; it cannot be split finer.
                out.append(rect.area)
                continue
            }
            let countA = density.count(a)
            queue.append((a, max(1, (countA + cap - 1) / cap)))
            queue.append((b, max(1, (count - countA + cap - 1) / cap)))
        }
        // A stable order: south to north, then west to east.
        out.sort { ($0.minLat, $0.minLon) < ($1.minLat, $1.minLon) }
        // Not trimmed back to the cells that hold nodes: the areas partition the ground
        // exactly, and trimming would leave ground in no tile, which draws as blank.
        return out
    }

    /// The result of the node pass: which areas every node belongs to, and how many nodes
    /// were seen.
    // Not private: the split is several files now, and Swift's `private` is one file.
    struct Assignment {
        var nodes: NodeAreas
        var total: Int
    }

    private func assignNodes(lookup: AreaLookup) throws -> Assignment {
        var expected = countedNodes
        if expected == 0 {
            // Only when the areas came ready-made: nothing has read the file yet.
            var counter = NodeCounter()
            for input in options.inputs { try PBFReader(url: input).read(into: &counter) }
            expected = counter.nodes
        } else {
            // Room for the fringe, which density did not count; growing the table later
            // would hold the old copy and the new one at once.
            expected += expected / 16 + 1024
        }
        let nodes = NodeAreas(expecting: expected)
        // Which tiles a node belongs to is a grid lookup depending on nothing else; only
        // the appending has to stay in order.
        for input in options.inputs {
            try PBFReader(url: input).readInOrder(make: { NodeAssign(lookup: lookup) }) {
                pass in
                let base = nodes.count
                nodes.append(ids: pass.ids, values: pass.values)
                // Interning is shared state, so a shared-line node's set is named here
                // rather than on the worker.
                for entry in pass.shared {
                    nodes.setValue(at: base + entry.at, to: nodes.intern(entry.areas))
                }
                for entry in pass.banded {
                    nodes.setValue(at: base + entry.at,
                                   to: nodes.internBand(strict: entry.strict,
                                                        shape: entry.shape))
                }
                pass.clear()
            }
            nodes.markFileEnd()
        }
        nodes.seal()
        return Assignment(nodes: nodes, total: nodes.count)
    }

    private struct NodeCounter: OSMSink {
        let wantedParts: OSMParts = .nodes

        var nodes = 0
        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) { nodes += 1 }
    }

    /// One block's mapping of node to tiles, worked out on any core. A shared-line node's
    /// set is named here and interned when the block is applied.
    private struct NodeAssign: OSMSink {
        let wantedParts: OSMParts = .nodes

        let lookup: AreaLookup
        var ids: [Int64] = []
        var values: [UInt16] = []
        /// Position in `values` to the set it stands for, for the few on a shared line.
        var shared: [(at: Int, areas: AreaLookup.Hits)] = []
        /// Position in `values` to the pair it stands for, for a node in a neighbour's
        /// shape band: where it lives, and where a shape through it must be delivered.
        var banded: [(at: Int, strict: AreaLookup.Hits, shape: AreaLookup.Hits)] = []

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            let mapLat = TileSplitter.mapUnits(lat)
            let mapLon = TileSplitter.mapUnits(lon)
            let hits = lookup.areas(lat: mapLat, lon: mapLon)
            ids.append(id)

            // Only a node that belongs somewhere can widen; one outside every tile is
            // beyond the map.
            if hits.count > 0 {
                let shape = lookup.shapeAreas(lat: mapLat, lon: mapLon)
                if shape.count > hits.count {
                    banded.append((values.count, hits.inOrder, shape.inOrder))
                    values.append(NodeAreas.outside)
                    return
                }
            }
            switch hits.count {
            case 0: values.append(NodeAreas.outside)
            case 1: values.append(hits.first)
            default:
                shared.append((values.count, hits.inOrder))
                values.append(NodeAreas.outside)
            }
        }

        mutating func clear() {
            ids.removeAll(keepingCapacity: true)
            values.removeAll(keepingCapacity: true)
            shared.removeAll(keepingCapacity: true)
            banded.removeAll(keepingCapacity: true)
        }
    }

    // MARK: Pass 2 — the problem list

}
