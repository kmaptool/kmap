import Foundation

/// The last pass: handing every object to the tiles that need it, and closing the files.
///
/// One walk of the extract per kind -- a tile's nodes must all precede its ways -- with
/// the decoding on every core and the handing over on the one thread that has to stay in
/// file order.
extension TileSplitter {
    func write(areas: [Area], assignment: Assignment, plan: Plan) throws -> [Int] {
        var writers: [TileWriter] = []
        for (index, area) in areas.enumerated() {
            let url = options.outputDirectory
                .appendingPathComponent("\(options.mapID + index).osm.pbf")
            writers.append(try TileWriter(url: url, area: area))
        }
        do {
            return try write(into: writers, assignment: assignment, plan: plan)
        } catch {
            // A tile half written looks whole to the next stage; none stays.
            for writer in writers {
                try? writer.finish()
                FileTools.removeIfPresent(writer.url)
            }
            throw error
        }
    }

    private func write(into writers: [TileWriter], assignment: Assignment, plan: Plan) throws -> [Int] {
        // 2 sweeps, so that with several inputs every tile still comes out nodes first,
        // then ways, then relations -- the order the format demands. Decoding a block and
        // choosing each object's tiles runs on every core; only the handing over stays in
        // file order, where the first copy of a repeat counts.
        try writeNodes(into: writers, assignment: assignment, plan: plan)
        if Measured.reported {
            log(String(format: "  nodes written, up to %@", Fmt.bytes(Machine.memoryInUse())))
        }
        try writeWaysAndRelations(into: writers, assignment: assignment, plan: plan)
        try Self.finish(writers)
        return writers.map(\.nodeCount)
    }

    /// A write pass for every block of `phase`.
    private func pass(_ phase: WritePass.Phase, assignment: Assignment, plan: Plan, tiles: Int) -> () -> WritePass {
        let overlapping = options.inputs.count > 1
        // Few ways are planned for, and every way asks: the filter answers most of them.
        let planned = IDFilter(Array(plan.wayTiles.keys))
        return {
            WritePass(
                nodes: assignment.nodes,
                cursor: NodeAreas.Cursor(assignment.nodes),
                plan: plan,
                plannedWays: planned,
                phase: phase,
                tiles: overlapping ? 0 : tiles
            )
        }
    }

    private func writeNodes(into writers: [TileWriter], assignment: Assignment, plan: Plan) throws {
        let overlapping = options.inputs.count > 1
        var repeats = NodeRepeats(assignment.nodes, inputs: options.inputs.count)
        for (fileIndex, input) in options.inputs.enumerated() {
            repeats.start(file: fileIndex)
            let make = pass(.nodes, assignment: assignment, plan: plan, tiles: writers.count)
            try reader(input).readInOrder(make: make) { pass in
                for i in 0..<pass.nodeBuckets.count {
                    writers[Int(pass.nodeBuckets.tiles[i])].add(nodes: pass.nodeBuckets.chunks[i])
                }
                for (node, tile, span) in pass.outNodes {
                    if overlapping, repeats.repeated(node.id) { continue }
                    if tile == WritePass.several {
                        for one in pass.spans[Int(span)] { writers[Int(one)].add(node) }
                    } else {
                        writers[Int(tile)].add(node)
                    }
                }
                try Self.stopIfAnyFailed(writers)
            }
        }
    }

    private func writeWaysAndRelations(into writers: [TileWriter], assignment: Assignment, plan: Plan) throws {
        let overlapping = options.inputs.count > 1
        var seenWays: Set<Int64> = []
        var seenRelations: Set<Int64> = []
        for input in options.inputs {
            let make = pass(.waysAndRelations, assignment: assignment, plan: plan, tiles: writers.count)
            try reader(input).readInOrder(make: make) { pass in
                for i in 0..<pass.wayBuckets.count {
                    writers[Int(pass.wayBuckets.tiles[i])].add(ways: pass.wayBuckets.chunks[i])
                }
                for (way, tile, span) in pass.outWays {
                    if overlapping, !seenWays.insert(way.id).inserted { continue }
                    if tile == WritePass.several {
                        for one in pass.spans[Int(span)] { writers[Int(one)].add(way) }
                    } else {
                        writers[Int(tile)].add(way)
                    }
                }
                for (relation, span) in pass.outRelations {
                    if overlapping, !seenRelations.insert(relation.id).inserted { continue }
                    for tile in pass.spans[Int(span)] { writers[Int(tile)].add(relation) }
                }
                try Self.stopIfAnyFailed(writers)
            }
        }
    }

    /// Each writer finishes independently: the last batches compress and the file closes
    /// per tile.
    private static func finish(_ writers: [TileWriter]) throws {
        var failures = [Error?](repeating: nil, count: writers.count)
        failures.withUnsafeMutableBufferPointer { slots in
            // Each lane finishes its own writer into its own slot: nothing is shared.
            nonisolated(unsafe) let slots = slots
            nonisolated(unsafe) let writers = writers
            DispatchQueue.concurrentPerform(iterations: writers.count) { index in
                do { try writers[index].finish() } catch { slots[index] = error }
            }
        }
        if let failure = failures.compactMap({ $0 }).first { throw failure }
    }

    /// Which nodes an earlier input already wrote, where several inputs overlap. Ids ascend
    /// within each extract, so a repeat is found by merging, a cursor per earlier file
    /// walking it in step with the arriving ids; an extract whose ids are not sorted falls
    /// back to a set of every id seen.
    private struct NodeRepeats {
        let nodes: NodeAreas
        let mergeable: Bool
        var earlier: [NodeAreas.FileCursor] = []
        var seen: Set<Int64> = []

        init(_ nodes: NodeAreas, inputs: Int) {
            self.nodes = nodes
            mergeable = !nodes.filesInterleave && nodes.fileEnds.count == inputs
        }

        mutating func start(file: Int) {
            earlier = mergeable ? nodes.fileCursors(before: file) : []
        }

        mutating func repeated(_ id: Int64) -> Bool {
            guard mergeable else { return !seen.insert(id).inserted }
            for i in earlier.indices where earlier[i].contains(id) { return true }
            return false
        }
    }

    /// A disk that filled during the first tile must not cost the sweep of the others.
    private static func stopIfAnyFailed(_ writers: [TileWriter]) throws {
        for writer in writers {
            if let failure = writer.failure { throw failure }
        }
    }

    /// One tile being written: batches of a few thousand objects, flushed as they fill.
    final class TileWriter {
        let url: URL
        let area: Area
        private let writer: PBFWriter
        /// The first write that failed, as soon as the writer's queue saw it.
        var failure: Error? { writer.writeFailure }
        private var nodes: [PBFWriter.Node] = []
        private var ways: [PBFWriter.Way] = []
        private var relations: [PBFWriter.Relation] = []
        /// Runs of a batch still filling, and how many elements they come to. A build
        /// hands over either single elements or runs, never both.
        private var nodeRuns: [(chunk: PBFWriter.NodeChunk, range: Range<Int>)] = []
        private var nodesInRuns = 0
        private var wayRuns: [(chunk: PBFWriter.WayChunk, range: Range<Int>)] = []
        private var waysInRuns = 0
        private(set) var nodeCount = 0

        init(url: URL, area: Area) throws {
            self.url = url
            self.area = area
            writer = try PBFWriter(to: url)
            writer.header(
                bbox: (
                    minLat: TileSplitter.degrees(area.minLat),
                    minLon: TileSplitter.degrees(area.minLon),
                    maxLat: TileSplitter.degrees(area.maxLat),
                    maxLon: TileSplitter.degrees(area.maxLon)
                )
            )
        }

        private static let nodesPerBatch = 16000
        private static let waysPerBatch = 4000

        func add(_ node: PBFWriter.Node) {
            nodes.append(node)
            nodeCount += 1
            if nodes.count >= Self.nodesPerBatch { writer.nodes(nodes); nodes.removeAll(keepingCapacity: true) }
        }

        /// The same as adding each in turn, batches cut at the same places; the run is
        /// kept as it is, a batch holding the stretch of it that is its own.
        func add(nodes run: PBFWriter.NodeChunk) {
            nodeCount += run.count
            var at = 0
            while at < run.count {
                let take = min(run.count - at, Self.nodesPerBatch - nodesInRuns)
                nodeRuns.append((run, at..<(at + take)))
                nodesInRuns += take
                at += take
                if nodesInRuns >= Self.nodesPerBatch { flushNodeRuns() }
            }
        }

        private func flushNodeRuns() {
            guard nodesInRuns > 0 else { return }
            writer.nodes(runs: nodeRuns)
            nodeRuns.removeAll(keepingCapacity: true)
            nodesInRuns = 0
        }

        private func flushWayRuns() {
            guard waysInRuns > 0 else { return }
            writer.ways(runs: wayRuns)
            wayRuns.removeAll(keepingCapacity: true)
            waysInRuns = 0
        }

        func add(_ way: PBFWriter.Way) {
            flushNodes()
            ways.append(way)
            if ways.count >= Self.waysPerBatch { writer.ways(ways); ways.removeAll(keepingCapacity: true) }
        }

        /// The same as adding each in turn, batches cut at the same places.
        func add(ways run: PBFWriter.WayChunk) {
            guard run.count > 0 else { return }
            flushNodes()
            var at = 0
            while at < run.count {
                let take = min(run.count - at, Self.waysPerBatch - waysInRuns)
                wayRuns.append((run, at..<(at + take)))
                waysInRuns += take
                at += take
                if waysInRuns >= Self.waysPerBatch { flushWayRuns() }
            }
        }

        func add(_ relation: PBFWriter.Relation) {
            flushNodes()
            flushWayRuns()
            if !ways.isEmpty { writer.ways(ways); ways.removeAll(keepingCapacity: true) }
            relations.append(relation)
            if relations.count >= 4000 {
                writer.relations(relations)
                relations.removeAll(keepingCapacity: true)
            }
        }

        private func flushNodes() {
            flushNodeRuns()
            if !nodes.isEmpty { writer.nodes(nodes); nodes.removeAll(keepingCapacity: true) }
        }

        func finish() throws {
            flushNodes()
            flushWayRuns()
            if !ways.isEmpty { writer.ways(ways) }
            if !relations.isEmpty { writer.relations(relations) }
            try writer.finish()
        }
    }

    private struct WritePass: OSMSink {
        enum Phase { case nodes, waysAndRelations }

        /// The write pass walks the extract twice -- a tile's nodes must all precede its
        /// ways -- and each walk asks for only what it is going to write.
        var wantedParts: OSMParts { phase == .nodes ? .nodes : [.ways, .relations] }
        let nodes: NodeAreas
        /// Walks the table alongside the nodes, which arrive in the order it was filled.
        let cursor: NodeAreas.Cursor
        let plan: Plan
        /// Says no for nearly every way the plan does not name, before its table is asked.
        let plannedWays: IDFilter
        let phase: Phase
        /// With 1 input, a block's nodes and ways sorted by tile here, each tile's in
        /// the block's order, so the serial hand-over takes a run per tile. Several inputs
        /// drop repeats 1 object at a time, in the lists below instead.
        var nodeBuckets: NodeBuckets
        var wayBuckets: WayBuckets
        var grouped: Bool { nodeBuckets.tileCount > 0 }
        /// What this block came to, in the order the block had it -- which is the order a
        /// tile must receive it in. Nearly everything goes to exactly one tile, so `tile`
        /// says which; the few that go to several point into `spans` instead.
        var outNodes: [(node: PBFWriter.Node, tile: UInt16, span: Int32)] = []
        /// Ways as records into two flat arrays rather than a pair of arrays each, built
        /// here on the worker so the serial hand-over allocates nothing per way.
        var outWays: [(way: PBFWriter.Way, tile: UInt16, span: Int32)] = []
        var outRelations: [(relation: PBFWriter.Relation, span: Int32)] = []
        var spans: [[UInt16]] = []

        /// Marks an object as going to more than one tile.
        static let several: UInt16 = .max

        /// Where this sink's walk through `plan.extra` has reached. One per sink, like
        /// the node cursor beside it, because each sink's queries ascend on their own.
        var extraAt = 0
        /// Scratch for a node's tiles on the general path.
        private var union: [UInt16] = []

        init(
            nodes: NodeAreas,
            cursor: NodeAreas.Cursor,
            plan: Plan,
            plannedWays: IDFilter,
            phase: Phase,
            tiles: Int
        ) {
            self.nodes = nodes
            self.cursor = cursor
            self.plan = plan
            self.plannedWays = plannedWays
            self.phase = phase
            nodeBuckets = NodeBuckets(tiles: phase == .nodes ? tiles : 0)
            wayBuckets = WayBuckets(tiles: phase == .nodes ? 0 : tiles)
        }

        /// Emptied by the worker before the next block rather than by the serial
        /// hand-over, which only reads it.
        mutating func begin(_ block: OSMBlock) {
            nodeBuckets.clear()
            wayBuckets.clear()
            outNodes.removeAll(keepingCapacity: true)
            outWays.removeAll(keepingCapacity: true)
            outRelations.removeAll(keepingCapacity: true)
            spans.removeAll(keepingCapacity: true)
        }

        /// One way as the writer wants it, built where the block's text is at hand.
        private func built(
            _ id: Int64,
            _ refs: ArraySlice<Int64>,
            _ keys: ArraySlice<Int32>,
            _ values: ArraySlice<Int32>,
            _ block: OSMBlock
        ) -> PBFWriter.Way {
            PBFWriter.Way(id: id, refs: refs.exactly, tags: tags(keys, values, block))
        }

        private func tags(
            _ keys: ArraySlice<Int32>,
            _ values: ArraySlice<Int32>,
            _ block: OSMBlock
        ) -> [(String, String)] {
            zip(keys, values).map { (block.text(Int($0)), block.text(Int($1))) }
        }

        private func denseTags(_ run: ArraySlice<Int32>, _ block: OSMBlock) -> [(String, String)] {
            var out: [(String, String)] = []
            var index = run.startIndex
            while index + 1 < run.endIndex {
                out.append((block.text(Int(run[index])), block.text(Int(run[index + 1]))))
                index += 2
            }
            return out
        }

        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags run: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            guard phase == .nodes else { return }
            let stored = cursor.value(for: id)
            // The cursor through a local: handing `extraAt` itself inout while `plan` is
            // read would copy the plan's table out of `self`, and retain it, every node.
            var at = extraAt
            let extra = plan.extra.isEmpty ? nil : plan.extra.tiles(for: id, walking: &at)
            extraAt = at

            // Nearly every node is inside exactly 1 tile and named by no repair; the
            // general path below gathers and sorts its tiles.
            if extra == nil, let stored, stored != NodeAreas.outside, stored & NodeAreas.flags == 0 {
                if grouped {
                    nodeBuckets.add(id: id, lat: lat, lon: lon, tags: run, block: block, to: stored)
                } else {
                    let node = PBFWriter.Node(id: id, lat: lat, lon: lon, tags: denseTags(run, block))
                    outNodes.append((node, stored, -1))
                }
                return
            }
            let tiles = takeTiles(stored: stored, extra: extra)
            defer { union = tiles }
            guard !tiles.isEmpty else { return }
            if grouped {
                for tile in tiles { nodeBuckets.add(id: id, lat: lat, lon: lon, tags: run, block: block, to: tile) }
            } else {
                spans.append(tiles)
                let node = PBFWriter.Node(id: id, lat: lat, lon: lon, tags: denseTags(run, block))
                outNodes.append((node, Self.several, Int32(spans.count - 1)))
            }
        }

        /// Every tile a node goes to, once each and in order: its own, and any a repair
        /// adds. Gathered in the buffer kept between nodes, which the caller hands back.
        private mutating func takeTiles(stored: UInt16?, extra: Range<Int>?) -> [UInt16] {
            var tiles: [UInt16] = []
            swap(&tiles, &union)
            tiles.removeAll(keepingCapacity: true)
            if let extra { for i in extra { tiles.append(plan.extra.poolTiles[i]) } }
            if let stored { nodes.appendAreas(of: stored, to: &tiles) }
            guard !tiles.isEmpty else { return tiles }
            tiles.sort()
            var kept = 1
            for i in 1..<tiles.count where tiles[i] != tiles[kept - 1] {
                tiles[kept] = tiles[i]
                kept += 1
            }
            tiles.removeLast(tiles.count - kept)
            return tiles
        }

        mutating func way(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            guard phase == .waysAndRelations else { return }
            let planned = plannedWays.mayContain(id) ? plan.wayTiles[id] : nil
            // The same shortcut as for nodes: a way the plan says nothing about lies in
            // 1 tile, and its first node inside the map names it.
            let bucketed = wayBuckets.tileCount > 0
            if planned == nil, let tile = singleTile(of: refs) {
                if bucketed {
                    wayBuckets.add(id: id, refs: refs, keys: keys, values: values, block: block, to: tile)
                } else {
                    outWays.append((built(id, refs, keys, values, block), tile, -1))
                }
                return
            }
            let tiles = wayTiles(planned: planned, refs: refs)
            guard !tiles.isEmpty else { return }
            if bucketed {
                for tile in tiles {
                    wayBuckets.add(id: id, refs: refs, keys: keys, values: values, block: block, to: tile)
                }
            } else {
                spans.append(tiles)
                outWays.append((built(id, refs, keys, values, block), Self.several, Int32(spans.count - 1)))
            }
        }

        /// The tile of the way's first node inside the map, when that node is in 1 tile only.
        private func singleTile(of refs: ArraySlice<Int64>) -> UInt16? {
            for ref in refs {
                guard let value = nodes.get(ref), value != NodeAreas.outside else { continue }
                return value & NodeAreas.flags == 0 ? value : nil
            }
            return nil
        }

        /// Every tile a way goes to, in order: the plan's, or else its first placed node's.
        private func wayTiles(planned: Int32?, refs: ArraySlice<Int64>) -> [UInt16] {
            var tiles = planned.map { Set(plan.sets[$0]) } ?? []
            if tiles.isEmpty {
                for ref in refs {
                    guard let value = nodes.get(ref) else { continue }
                    let areas = nodes.areas(of: value)
                    guard !areas.isEmpty else { continue }
                    tiles.formUnion(areas)
                    break  // a non-spanning way has only 1
                }
            }
            return tiles.sorted()
        }

        mutating func relation(
            id: Int64,
            memberKinds: ArraySlice<Int32>,
            memberIDs: ArraySlice<Int64>,
            memberRoles: ArraySlice<Int32>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            guard phase == .waysAndRelations else { return }
            // Already in order: the sets are sorted when they are interned.
            let tiles = plan.relationTiles[id].map { plan.sets[$0] } ?? []
            guard !tiles.isEmpty else { return }
            var members: [PBFWriter.Relation.Member] = []
            for (index, (kind, ref)) in zip(memberKinds, memberIDs).enumerated() {
                let roleIndex = memberRoles.startIndex + index
                let role =
                    roleIndex < memberRoles.endIndex
                    ? block.text(Int(memberRoles[roleIndex])) : ""
                members.append(.init(kind: kind, ref: ref, role: role))
            }
            spans.append(tiles)
            outRelations.append(
                (
                    PBFWriter.Relation(
                        id: id,
                        members: members,
                        tags: tags(keys, values, block)
                    ),
                    Int32(spans.count - 1)
                )
            )
        }
    }

    /// Which run of a block's objects each tile has: 1 run per tile the block touches, in
    /// the order first met. Kept between blocks.
    struct TileRuns {
        /// The tiles with a run, `count` of them; slots past that are spare.
        private(set) var tiles: [UInt16] = []
        private(set) var count = 0
        /// Per tile, its run, or -1.
        private var runOf: [Int32]

        init(tiles: Int) {
            runOf = [Int32](repeating: -1, count: tiles)
        }

        var tileCount: Int { runOf.count }

        /// The tile's run, and whether this call opened it.
        mutating func run(for tile: UInt16) -> (run: Int, opened: Bool) {
            let held = Int(runOf[Int(tile)])
            if held >= 0 { return (held, false) }
            let run = count
            runOf[Int(tile)] = Int32(run)
            if count == tiles.count { tiles.append(tile) } else { tiles[count] = tile }
            count += 1
            return (run, true)
        }

        mutating func clear() {
            for run in 0..<count { runOf[Int(tiles[run])] = -1 }
            count = 0
        }
    }

    /// The strings a run has taken from its block, numbered in the order first met.
    /// `places` answers for a block's own number; the slot past the last stands for any
    /// number the block does not hold, which reads as the empty text.
    struct RunStrings {
        private var places: [Int32] = []

        mutating func open(for block: OSMBlock) {
            places.removeAll(keepingCapacity: true)
            places.append(contentsOf: repeatElement(-1, count: block.strings.count + 1))
        }

        @inline(__always)
        mutating func place(of source: Int32, in block: OSMBlock, among strings: inout [String]) -> Int32 {
            let last = places.count - 1
            let slot = source >= 0 && Int(source) < last ? Int(source) : last
            let known = places[slot]
            if known >= 0 { return known }
            let made = Int32(strings.count)
            strings.append(block.text(Int(source)))
            places[slot] = made
            return made
        }
    }

    /// A block's nodes by tile, each tile's as 1 run in the block's order.
    struct NodeBuckets {
        private(set) var runs: TileRuns
        private(set) var chunks: [PBFWriter.NodeChunk] = []
        private var strings: [RunStrings] = []

        init(tiles: Int) { runs = TileRuns(tiles: tiles) }

        var tileCount: Int { runs.tileCount }
        var count: Int { runs.count }
        var tiles: [UInt16] { runs.tiles }

        mutating func add(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock,
            to tile: UInt16
        ) {
            let (run, opened) = runs.run(for: tile)
            if run == chunks.count {
                chunks.append(PBFWriter.NodeChunk())
                strings.append(RunStrings())
            }
            if opened { strings[run].open(for: block) }
            chunks[run].ids.append(id)
            chunks[run].lats.append(lat)
            chunks[run].lons.append(lon)
            var index = tags.startIndex
            while index + 1 < tags.endIndex {
                let key = strings[run].place(of: tags[index], in: block, among: &chunks[run].strings)
                let value = strings[run].place(of: tags[index + 1], in: block, among: &chunks[run].strings)
                chunks[run].tags.append(key)
                chunks[run].tags.append(value)
                index += 2
            }
            chunks[run].tagEnds.append(Int32(chunks[run].tags.count))
        }

        /// Empties the runs. The storage went to the tile's writer with the run, which
        /// keeps it until the batch is written, so each run starts on storage of its own,
        /// sized by what it held: keeping the capacity would copy the largest block's.
        mutating func clear() {
            for run in 0..<runs.count {
                let held = chunks[run]
                chunks[run] = PBFWriter.NodeChunk()
                chunks[run].ids.reserveCapacity(held.ids.count)
                chunks[run].lats.reserveCapacity(held.ids.count)
                chunks[run].lons.reserveCapacity(held.ids.count)
                chunks[run].tagEnds.reserveCapacity(held.ids.count)
                chunks[run].tags.reserveCapacity(held.tags.count)
                chunks[run].strings.reserveCapacity(held.strings.count)
            }
            runs.clear()
        }
    }

    /// A block's ways by tile, each tile's as 1 run in the block's order.
    struct WayBuckets {
        private(set) var runs: TileRuns
        private(set) var chunks: [PBFWriter.WayChunk] = []
        private var strings: [RunStrings] = []

        init(tiles: Int) { runs = TileRuns(tiles: tiles) }

        var tileCount: Int { runs.tileCount }
        var count: Int { runs.count }
        var tiles: [UInt16] { runs.tiles }

        mutating func add(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock,
            to tile: UInt16
        ) {
            let (run, opened) = runs.run(for: tile)
            if run == chunks.count {
                chunks.append(PBFWriter.WayChunk())
                strings.append(RunStrings())
            }
            if opened { strings[run].open(for: block) }
            chunks[run].ids.append(id)
            chunks[run].refs.append(contentsOf: refs)
            chunks[run].refEnds.append(Int32(chunks[run].refs.count))
            for (key, value) in zip(keys, values) {
                let keyPlace = strings[run].place(of: key, in: block, among: &chunks[run].strings)
                let valuePlace = strings[run].place(of: value, in: block, among: &chunks[run].strings)
                chunks[run].tags.append(keyPlace)
                chunks[run].tags.append(valuePlace)
            }
            chunks[run].tagEnds.append(Int32(chunks[run].tags.count))
        }

        mutating func clear() {
            for run in 0..<runs.count {
                let held = chunks[run]
                chunks[run] = PBFWriter.WayChunk()
                chunks[run].ids.reserveCapacity(held.ids.count)
                chunks[run].refEnds.reserveCapacity(held.ids.count)
                chunks[run].refs.reserveCapacity(held.refs.count)
                chunks[run].tagEnds.reserveCapacity(held.ids.count)
                chunks[run].tags.reserveCapacity(held.tags.count)
                chunks[run].strings.reserveCapacity(held.strings.count)
            }
            runs.clear()
        }
    }

    // MARK: The two companion files

    func writeAreasList(
        _ tiles: [(mapID: String, area: Area, nodes: Int)],
        to url: URL
    ) throws {
        var text = "# List of areas\n# Generated by kmap\n#\n"
        for tile in tiles {
            let a = tile.area
            text += "\(tile.mapID): \(a.minLat),\(a.minLon) to \(a.maxLat),\(a.maxLon)\n"
            text += String(
                format: "#       : %f,%f to %f,%f\n\n",
                Self.degrees(a.minLat),
                Self.degrees(a.minLon),
                Self.degrees(a.maxLat),
                Self.degrees(a.maxLon)
            )
        }
        try FileTools.write(text, to: url)
    }

    func writeTemplateArgs(
        _ tiles: [(mapID: String, area: Area, nodes: Int)],
        to url: URL
    ) throws {
        var text = "#\n# This file can be given to mkgmap using the -c option\n#\n"
        for tile in tiles {
            text += "\nmapname: \(tile.mapID)\n"
            text += "description: \(options.description)\n"
            text += "input-file: \(tile.mapID).osm.pbf\n"
        }
        try FileTools.write(text, to: url)
    }
}
