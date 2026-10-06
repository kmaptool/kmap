import Foundation

extension TileSplitter {
    struct WritePass: OSMSink {
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
            if let planned, case let tiles = plan.sets[planned], !tiles.isEmpty { return Self.distinct(tiles) }
            for ref in refs {
                guard let value = nodes.get(ref) else { continue }
                let areas = nodes.areas(of: value)
                guard !areas.isEmpty else { continue }
                return Self.distinct(areas)  // a non-spanning way has only 1
            }
            return []
        }

        /// Ascending and once each: interned sets already are, so no set is built for them.
        private static func distinct(_ tiles: [UInt16]) -> [UInt16] {
            for i in tiles.indices.dropFirst() where tiles[i - 1] >= tiles[i] { return Set(tiles).sorted() }
            return tiles
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
}
