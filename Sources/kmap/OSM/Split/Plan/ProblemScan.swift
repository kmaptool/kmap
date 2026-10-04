import Foundation

extension TileSplitter {
    /// One block's mapping of way to the tiles it touches, computed on any core. Recording
    /// the result stays in order, since the tables it feeds are shared.
    struct ProblemScan: OSMSink {
        let wantedParts: OSMParts = [.ways, .relations]

        let nodes: NodeAreas
        /// Ways of this block in the block's own order, which is by ascending id, since
        /// the table they go into is built by appending. `tile` is the single tile, or
        /// `several` when `span` points into `spans`.
        var outWays: [(id: Int64, tile: UInt16, span: Int32)] = []
        var spans: [Set<UInt16>] = []
        static let several: UInt16 = .max
        /// Relations are left whole for the ordered pass: what tiles they reach depends on
        /// every way having been recorded, and blocks are decoded out of turn.
        var rawRelations: [(id: Int64, record: RelationRecord)] = []

        init(nodes: NodeAreas) {
            self.nodes = nodes
        }

        mutating func clear() {
            outWays.removeAll(keepingCapacity: true)
            spans.removeAll(keepingCapacity: true)
            rawRelations.removeAll(keepingCapacity: true)
        }

        /// Ways of this block not yet placed: their ids, whether each is drawn but not
        /// routed, and their nodes end to end. `end(_:)` places them all at once.
        private var waysHeld: [(id: Int64, drawnNotRouted: Bool, refsEnd: Int)] = []
        private var refsHeld: [Int64] = []
        /// Where each held node sits in the table, from 1 search for the whole block.
        private var found: [Int64] = []

        mutating func way(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            // A closed way or a contour is drawn but not routed and must reach every tile
            // whose shape band it falls in; a routed way is clipped to the frame exactly.
            let closed = refs.count >= Self.leastClosedRefs && refs.first == refs.last
            refsHeld.append(contentsOf: refs)
            waysHeld.append((id, closed || Self.isContour(keys, values, block), refsHeld.count))
        }

        /// A closed way's fewest refs: 3 corners and the first again.
        private static let leastClosedRefs = 4

        /// Looks up every node of the block's ways in 1 batch, so that thousands of
        /// searches wait on memory together, then places the ways in the order they came.
        mutating func end(_ block: OSMBlock) {
            guard !waysHeld.isEmpty else { return }
            if found.count < refsHeld.count { found = [Int64](repeating: 0, count: refsHeld.count) }
            let batched = refsHeld.withUnsafeBufferPointer { ids in
                found.withUnsafeMutableBufferPointer { nodes.findAll(ids, into: $0.baseAddress!) }
            }
            var start = 0
            for (id, drawnNotRouted, end) in waysHeld {
                place(id, drawnNotRouted: drawnNotRouted, refs: start..<end, batched: batched)
                start = end
            }
            waysHeld.removeAll(keepingCapacity: true)
            refsHeld.removeAll(keepingCapacity: true)
        }

        private mutating func place(_ id: Int64, drawnNotRouted: Bool, refs held: Range<Int>, batched: Bool) {
            var claims = TileClaims()
            for at in held {
                guard let value = value(at: at, batched: batched) else { continue }
                if value == NodeAreas.outside {
                    claims.sawOutside = true
                } else if value & NodeAreas.flags == 0 {
                    claims.claim(value)
                } else {
                    // On a shared line, or in a neighbour's band: names several tiles.
                    let areas = drawnNotRouted ? nodes.shapeAreas(of: value) : nodes.areas(of: value)
                    for area in areas { claims.claim(area) }
                }
            }
            record(id, claims)
        }

        /// The stored value of the held node `at`, or nil when the table does not have it.
        private func value(at held: Int, batched: Bool) -> UInt16? {
            guard batched else { return nodes.get(refsHeld[held]) }
            return found[held] >= 0 ? nodes.value(at: Int(found[held])) : nil
        }

        private mutating func record(_ id: Int64, _ claims: TileClaims) {
            if let overflow = claims.overflow {
                spans.append(overflow)
                outWays.append((id, Self.several, Int32(spans.count - 1)))
            } else if claims.tiles.count == 1 && !claims.sawOutside {
                outWays.append((id, claims.tiles.first, -1))
            } else if claims.tiles.count > 0 {
                // Touches several tiles, or leaves the map: complete in each.
                spans.append(Set(claims.tiles.sorted))
                outWays.append((id, Self.several, Int32(spans.count - 1)))
            }
        }

        /// The tiles a way's nodes claim: a fixed-size list, spilled into a set once full,
        /// every further tile then going to the set.
        private struct TileClaims {
            var tiles = AreaLookup.Hits()
            var overflow: Set<UInt16>?
            var sawOutside = false

            mutating func claim(_ area: UInt16) {
                if overflow != nil {
                    overflow?.insert(area)
                } else if tiles.count == AreaLookup.Hits.capacity && !tiles.contains(area) {
                    var spilled = Set(tiles.sorted)
                    spilled.insert(area)
                    overflow = spilled
                } else {
                    tiles.add(area)
                }
            }
        }

        /// Whether the way is a contour, by the `contour=elevation` tag pyhgtmap writes.
        /// The split runs before the style, so there is no map type to test.
        private static func isContour(
            _ keys: ArraySlice<Int32>,
            _ values: ArraySlice<Int32>,
            _ block: OSMBlock
        ) -> Bool {
            for (key, value) in zip(keys, values) where block.text(Int(key)) == "contour" {
                return block.text(Int(value)) == "elevation"
            }
            return false
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
            var record = RelationRecord()
            for (kind, ref) in zip(memberKinds, memberIDs) {
                switch kind {
                case 0:
                    record.memberNodes.append(ref)
                    if let value = nodes.get(ref) {
                        record.directTiles.formUnion(nodes.areas(of: value))
                    } else {
                        record.hasMissingMember = true
                    }
                case 1:
                    record.memberWays.append(ref)
                default:
                    record.memberRelations.append(ref)
                }
            }
            for (key, value) in zip(keys, values) {
                if block.text(Int(key)) == "type" {
                    let type = block.text(Int(value))
                    record.fillsRings = type == "multipolygon" || type == "boundary"
                    record.carriesMembers =
                        record.fillsRings
                        || type == "restriction" || type == "associatedStreet"
                }
            }
            rawRelations.append((id, record))
        }
    }
}
