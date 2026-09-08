import Foundation

/// The passes over the extract the plan is read from: the problem scan, and the
/// two small sinks that resolve refs and coordinates.
extension TileSplitter {
    /// One record per relation: enough to settle its tiles without holding the file.
    struct RelationRecord {
        var memberNodes: [Int64] = []
        var memberWays: [Int64] = []
        var memberRelations: [Int64] = []
        var directTiles: Set<UInt16> = []
        /// A member the extract does not hold; an incomplete relation of a carried type is
        /// written to every tile.
        var hasMissingMember = false
        /// The four types mkgmap must see complete: multipolygon and boundary for the
        /// geometry, restriction for routing, associatedStreet for house numbers. Only
        /// these have their members carried across tiles.
        var carriesMembers = false
        /// Ring fill applies to the two polygon kinds alone.
        var fillsRings = false
    }

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

        mutating func way(id: Int64, refs: ArraySlice<Int64>,
                          keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                          block: OSMBlock) {
            // A closed way or a contour is drawn but not routed and must reach every tile
            // whose shape band it falls in; a routed way is clipped to the frame exactly.
            let closed = refs.count > 3 && refs.first == refs.last
            let drawnNotRouted = closed || Self.isContour(keys, values, block)
            var tiles = AreaLookup.Hits()
            var overflow: Set<UInt16>?
            var sawOutside = false
            /// Adds one tile, spilling into `overflow` once the fixed-size hit list is
            /// full. Once spilled, every further tile goes to the set.
            func claim(_ area: UInt16) {
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
            for ref in refs {
                guard let value = nodes.get(ref) else { continue }
                if value == NodeAreas.outside {
                    sawOutside = true
                } else if value & NodeAreas.flags == 0 {
                    claim(value)
                } else {
                    // On a shared line, or in a neighbour's band: names several tiles.
                    for area in (drawnNotRouted ? nodes.shapeAreas(of: value)
                                                : nodes.areas(of: value)) {
                        claim(area)
                    }
                }
            }
            if let overflow {
                spans.append(overflow)
                outWays.append((id, Self.several, Int32(spans.count - 1)))
                return
            }
            if tiles.count == 1 && !sawOutside {
                outWays.append((id, tiles.first, -1))
            } else if tiles.count > 0 {
                // Touches several tiles, or leaves the map: complete in each.
                spans.append(Set(tiles.sorted))
                outWays.append((id, Self.several, Int32(spans.count - 1)))
            }
        }

        /// Whether the way is a contour, by the `contour=elevation` tag pyhgtmap writes.
        /// The split runs before the style, so there is no map type to test.
        private static func isContour(_ keys: ArraySlice<Int32>, _ values: ArraySlice<Int32>,
                                      _ block: OSMBlock) -> Bool {
            for (key, value) in zip(keys, values) where block.text(Int(key)) == "contour" {
                return block.text(Int(value)) == "elevation"
            }
            return false
        }

        mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                               memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                               keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                               block: OSMBlock) {
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
                    record.carriesMembers = record.fillsRings
                        || type == "restriction" || type == "associatedStreet"
                }
            }
            rawRelations.append((id, record))
        }
    }

    struct WayRefs: OSMSink {
        let wantedParts: OSMParts = .ways

        var wanted: WantedIDs
        var refs: [Int64: [Int64]] = [:]
        mutating func way(id: Int64, refs list: ArraySlice<Int64>,
                          keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                          block: OSMBlock) {
            if wanted.wants(id) { refs[id] = list.exactly }
        }
    }

    struct NodeCoords: OSMSink {
        let wantedParts: OSMParts = .nodes

        var wanted: WantedIDs
        var coords: [Int64: (lat: Int32, lon: Int32)] = [:]
        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            if wanted.wants(id) {
                coords[id] = (TileSplitter.mapUnits(lat), TileSplitter.mapUnits(lon))
            }
        }
    }
}
