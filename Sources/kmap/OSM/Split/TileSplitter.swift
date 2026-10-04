import Foundation

/// Splits one OSM extract into map tiles. An object inside one tile
/// and no other goes only there; a way or relation touching several is written complete to
/// each, and a multipolygon also to every tile its rings enclose. Areas are in Garmin map
/// units, degrees times 2^24 over 360, aligned to 2048 of them.
final class TileSplitter {
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
        /// How many relations are placed at a time; nil for the machine's own measure.
        /// For the tests, which hold too few relations to fill a window of their own.
        var relationWindow: Int?
        /// The fewest relations worth a lane of their own; nil for the measured one. For
        /// the tests too, so a small extract is placed on several lanes.
        var relationsPerLane: Int?
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case empty
        case tooManyAreas(Int)
        case tooManyTileSets

        var description: String {
            switch self {
            case .empty: "the extract holds no nodes"
            case .tooManyAreas(let n): "the split needs \(n) tiles, which is past every limit"
            case .tooManyTileSets: "the tiles meet in more ways than a split can name; build the region in parts"
            }
        }
    }

    // Not private: the split's passes live in files of their own, and Swift's `private`
    // is one file.
    let options: Options
    let log: (String) -> Void
    /// Told how far the split has come, 0...1, at each phase boundary. Reporting only -
    /// nothing inside the passes slows for it.
    var progress: ((Double) -> Void)?
    /// Asked between blobs and between phases; true ends the split with a
    /// `CancellationError` and no tiles. The reads run on their own threads, where a
    /// task's cancellation is not seen, so the caller's flag is what reaches them.
    var shouldStop: () -> Bool = { false }

    /// A reader on an input, carrying the stop flag.
    func reader(_ url: URL) -> PBFReader { PBFReader(url: url, shouldStop: shouldStop) }

    func stopIfAsked() throws {
        if shouldStop() { throw CancellationError() }
    }
    /// Nodes seen while measuring density, which is what sizes the node table. Zero when
    /// the areas were given and the measuring was skipped.
    var countedNodes = 0

    init(options: Options, log: @escaping (String) -> Void) {
        self.options = options
        self.log = log
    }

    // MARK: Units

    /// Garmin map units: 24 bits to the full circle.
    private static let unitsPerCircle = Double(1 << 24), degreesPerCircle = 360.0
    private static let halfCircle = Double(1 << 23)
    /// The node table's slack for the fringe: a sixteenth more, and never fewer than this.
    private static let fringeShare = 16, fringeFloor = 1024

    /// Converts degrees to Garmin map units, rounding as Java's Math.round does, floor of
    /// x plus a half, which is what splitter did.
    static func mapUnits(_ degrees: Double) -> Int32 {
        // Clamping, not trapping: a corrupt coordinate must miscount a node rather than
        // kill the split.
        // To the planet's edge, not Int32's: then any two differ by less than 2^24, and a
        // grid sized by the spread of nodes stays a planet, not a memory error.
        let units = (degrees * unitsPerCircle / degreesPerCircle + 0.5).rounded(.down)
        if !(units < halfCircle) { return Int32(halfCircle) }
        if units <= -halfCircle { return -Int32(halfCircle) }
        return Int32(units)
    }

    static func degrees(_ units: Int32) -> Double {
        Double(units) * degreesPerCircle / unitsPerCircle
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

    /// The two files written beside the tiles, which the compile stage reads.
    static let areasListName = "areas.list", templateArgsName = "template.args"

    /// How far along the split each phase boundary is, for the progress bar.
    private static let measured = 0.2, placed = 0.6, planned = 0.75

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
        progress?(Self.measured)
        try stopIfAsked()

        let lookup = AreaLookup(areas: areas, shapeOverlap: options.shapeOverlap)
        let assignment = try assignNodes(lookup: lookup)
        took("placed every node")
        progress?(Self.placed)
        try stopIfAsked()
        let plan = try planProblems(assignment: assignment, lookup: lookup, areas: areas)
        took("worked out what spans tiles")
        progress?(Self.planned)
        try stopIfAsked()
        let counts = try write(areas: areas, assignment: assignment, plan: plan)
        took("wrote the tiles")
        progress?(1)
        return try listTiles(areas, counts: counts)
    }

    /// The tiles written, named and counted, and the 2 companion files that list them.
    private func listTiles(_ areas: [Area], counts: [Int]) throws -> Result {
        let listURL = options.outputDirectory.appendingPathComponent(Self.areasListName)
        let argsURL = options.outputDirectory.appendingPathComponent(Self.templateArgsName)
        var tiles: [(mapID: String, area: Area, nodes: Int)] = []
        for (index, area) in areas.enumerated() {
            tiles.append(
                (
                    mapID: String(options.mapID + index), area: area,
                    nodes: counts[index]
                )
            )
        }
        try writeAreasList(tiles, to: listURL)
        try writeTemplateArgs(tiles, to: argsURL)
        return Result(tiles: tiles, areasList: listURL, templateArgs: argsURL)
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
            for input in options.inputs { try reader(input).read(into: &counter) }
            expected = counter.nodes
        } else {
            // Room for the fringe, which density did not count; growing the table later
            // would hold the old copy and the new one at once.
            expected += expected / Self.fringeShare + Self.fringeFloor
        }
        let nodes = NodeAreas(expecting: expected)
        // Which tiles a node belongs to is a grid lookup depending on nothing else; only
        // the appending has to stay in order.
        for input in options.inputs {
            try reader(input).readInOrder(make: { NodeAssign(lookup: lookup) }) {
                pass in
                let base = nodes.count
                nodes.append(ids: pass.ids, values: pass.values)
                // Interning is shared state, so a shared-line node's set is named here
                // rather than on the worker.
                for entry in pass.shared {
                    nodes.setValue(at: base + entry.at, to: nodes.intern(entry.areas))
                }
                let named = pass.bands.map { nodes.internBand(strict: $0.strict, shape: $0.shape) }
                for entry in pass.banded {
                    nodes.setValue(at: base + entry.at, to: named[entry.band])
                }
                pass.clear()
            }
            nodes.markFileEnd()
        }
        guard !nodes.overflowed else { throw Trouble.tooManyTileSets }
        nodes.seal()
        return Assignment(nodes: nodes, total: nodes.count)
    }

    private struct NodeCounter: OSMSink {
        let wantedParts: OSMParts = .nodes

        var nodes = 0
        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) { nodes += 1 }
    }
}
