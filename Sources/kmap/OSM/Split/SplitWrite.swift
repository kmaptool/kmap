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
        // Two sweeps, so that with several inputs every tile still comes out nodes first,
        // then ways, then relations -- the order the format demands.
        let overlapping = options.inputs.count > 1
        // Decoding a block and choosing each object's tiles runs on every core; only the
        // handing over stays in file order, where the first copy of a repeat counts.
        // A repeated node is dropped by merging rather than hashing: ids ascend within each
        // extract, so a cursor per earlier file walks it in step with the arriving ids.
        // An extract whose ids are not sorted falls back to the `seenNodes` set.
        let mergeable = !assignment.nodes.filesInterleave
            && assignment.nodes.fileEnds.count == options.inputs.count
        var seenNodes: Set<Int64> = []
        var seenWays: Set<Int64> = []
        var seenRelations: Set<Int64> = []

        for (fileIndex, input) in options.inputs.enumerated() {
            var earlier = mergeable && overlapping
                ? assignment.nodes.fileCursors(before: fileIndex) : []
            try PBFReader(url: input).readInOrder(make: {
                WritePass(nodes: assignment.nodes,
                          cursor: NodeAreas.Cursor(assignment.nodes),
                          plan: plan, phase: .nodes)
            }) { pass in
                for (node, tile, span) in pass.outNodes {
                    if overlapping {
                        if mergeable {
                            var repeated = false
                            for i in earlier.indices {
                                if earlier[i].contains(node.id) { repeated = true; break }
                            }
                            if repeated { continue }
                        } else if !seenNodes.insert(node.id).inserted {
                            continue
                        }
                    }
                    if tile == WritePass.several {
                        for one in pass.spans[Int(span)] { writers[Int(one)].add(node) }
                    } else {
                        writers[Int(tile)].add(node)
                    }
                }
                pass.clear()
            }
        }
        if Measured.reported {
            log(String(format: "  nodes written, up to %@", Fmt.bytes(Machine.memoryInUse())))
        }
        for input in options.inputs {
            try PBFReader(url: input).readInOrder(make: {
                WritePass(nodes: assignment.nodes,
                          cursor: NodeAreas.Cursor(assignment.nodes),
                          plan: plan, phase: .waysAndRelations)
            }) { pass in
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
                pass.clear()
            }
        }
        // Each writer finishes independently: the last batches compress and the file
        // closes per tile.
        var finishFailures = [Error?](repeating: nil, count: writers.count)
        finishFailures.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: writers.count) { index in
                do { try writers[index].finish() } catch { slots[index] = error }
            }
        }
        if let failure = finishFailures.compactMap({ $0 }).first { throw failure }
        return writers.map(\.nodeCount)
    }

    /// One tile being written: batches of a few thousand objects, flushed as they fill.
    final class TileWriter {
        let url: URL
        let area: Area
        private let writer: PBFWriter
        private var nodes: [PBFWriter.Node] = []
        private var ways: [PBFWriter.Way] = []
        private var relations: [PBFWriter.Relation] = []
        private(set) var nodeCount = 0

        init(url: URL, area: Area) throws {
            self.url = url
            self.area = area
            writer = try PBFWriter(to: url)
            writer.header(bbox: (minLat: TileSplitter.degrees(area.minLat),
                                 minLon: TileSplitter.degrees(area.minLon),
                                 maxLat: TileSplitter.degrees(area.maxLat),
                                 maxLon: TileSplitter.degrees(area.maxLon)))
        }

        func add(_ node: PBFWriter.Node) {
            nodes.append(node)
            nodeCount += 1
            if nodes.count >= 16000 { writer.nodes(nodes); nodes.removeAll(keepingCapacity: true) }
        }

        func add(_ way: PBFWriter.Way) {
            flushNodes()
            ways.append(way)
            if ways.count >= 4000 { writer.ways(ways); ways.removeAll(keepingCapacity: true) }
        }

        func add(_ relation: PBFWriter.Relation) {
            flushNodes()
            if !ways.isEmpty { writer.ways(ways); ways.removeAll(keepingCapacity: true) }
            relations.append(relation)
            if relations.count >= 4000 {
                writer.relations(relations)
                relations.removeAll(keepingCapacity: true)
            }
        }

        private func flushNodes() {
            if !nodes.isEmpty { writer.nodes(nodes); nodes.removeAll(keepingCapacity: true) }
        }

        func finish() throws {
            flushNodes()
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
        let phase: Phase
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

        mutating func clear() {
            outNodes.removeAll(keepingCapacity: true)
            outWays.removeAll(keepingCapacity: true)
            outRelations.removeAll(keepingCapacity: true)
            spans.removeAll(keepingCapacity: true)
        }

        /// One way as the writer wants it, built where the block's text is at hand.
        private func built(_ id: Int64, _ refs: ArraySlice<Int64>,
                           _ keys: ArraySlice<Int32>, _ values: ArraySlice<Int32>,
                           _ block: OSMBlock) -> PBFWriter.Way {
            PBFWriter.Way(id: id, refs: refs.exactly, tags: tags(keys, values, block))
        }

        private func tags(_ keys: ArraySlice<Int32>, _ values: ArraySlice<Int32>,
                          _ block: OSMBlock) -> [(String, String)] {
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

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags run: ArraySlice<Int32>, block: OSMBlock) {
            guard phase == .nodes else { return }
            let stored = cursor.value(for: id)
            let extra = plan.extra.isEmpty ? nil : plan.extra.tiles(for: id, walking: &extraAt)

            // Nearly every node is inside exactly one tile and named by no repair; the
            // general path below builds a set and two arrays for each.
            if extra == nil, let stored, stored != NodeAreas.outside,
               stored & NodeAreas.flags == 0 {
                outNodes.append((PBFWriter.Node(id: id, lat: lat, lon: lon,
                                                tags: denseTags(run, block)), stored, -1))
                return
            }

            var tiles = Set(extra ?? [])
            if let stored { tiles.formUnion(nodes.areas(of: stored)) }
            guard !tiles.isEmpty else { return }
            spans.append(tiles.sorted())
            outNodes.append((PBFWriter.Node(id: id, lat: lat, lon: lon,
                                            tags: denseTags(run, block)),
                             Self.several, Int32(spans.count - 1)))
        }

        mutating func way(id: Int64, refs: ArraySlice<Int64>,
                          keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                          block: OSMBlock) {
            guard phase == .waysAndRelations else { return }
            let planned = plan.wayTiles.isEmpty ? nil : plan.wayTiles[id]

            // The same shortcut as for nodes: a way the plan says nothing about lies in
            // one tile, and its first node inside the map names it.
            if planned == nil {
                for ref in refs {
                    guard let value = nodes.get(ref), value != NodeAreas.outside else {
                        continue
                    }
                    guard value & NodeAreas.flags == 0 else { break }
                    outWays.append((built(id, refs, keys, values, block), value, -1))
                    return
                }
            }

            var tiles = planned.map { Set(plan.sets[$0]) } ?? []
            if tiles.isEmpty {
                for ref in refs {
                    guard let value = nodes.get(ref) else { continue }
                    let areas = nodes.areas(of: value)
                    guard !areas.isEmpty else { continue }
                    tiles.formUnion(areas)
                    break                           // a non-spanning way has only one
                }
            }
            guard !tiles.isEmpty else { return }
            spans.append(tiles.sorted())
            outWays.append((built(id, refs, keys, values, block),
                            Self.several, Int32(spans.count - 1)))
        }

        mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                               memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                               keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                               block: OSMBlock) {
            guard phase == .waysAndRelations else { return }
            // Already in order: the sets are sorted when they are interned.
            let tiles = plan.relationTiles[id].map { plan.sets[$0] } ?? []
            guard !tiles.isEmpty else { return }
            var members: [PBFWriter.Relation.Member] = []
            for (index, (kind, ref)) in zip(memberKinds, memberIDs).enumerated() {
                let roleIndex = memberRoles.startIndex + index
                let role = roleIndex < memberRoles.endIndex
                    ? block.text(Int(memberRoles[roleIndex])) : ""
                members.append(.init(kind: kind, ref: ref, role: role))
            }
            spans.append(tiles)
            outRelations.append((PBFWriter.Relation(id: id, members: members,
                                                    tags: tags(keys, values, block)),
                                 Int32(spans.count - 1)))
        }
    }

    // MARK: The two companion files

    func writeAreasList(_ tiles: [(mapID: String, area: Area, nodes: Int)],
                                to url: URL) throws {
        var text = "# List of areas\n# Generated by kmap\n#\n"
        for tile in tiles {
            let a = tile.area
            text += "\(tile.mapID): \(a.minLat),\(a.minLon) to \(a.maxLat),\(a.maxLon)\n"
            text += String(format: "#       : %f,%f to %f,%f\n\n",
                           Self.degrees(a.minLat), Self.degrees(a.minLon),
                           Self.degrees(a.maxLat), Self.degrees(a.maxLon))
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeTemplateArgs(_ tiles: [(mapID: String, area: Area, nodes: Int)],
                                   to url: URL) throws {
        var text = "#\n# This file can be given to mkgmap using the -c option\n#\n"
        for tile in tiles {
            text += "\nmapname: \(tile.mapID)\n"
            text += "description: \(options.description)\n"
            text += "input-file: \(tile.mapID).osm.pbf\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

}
