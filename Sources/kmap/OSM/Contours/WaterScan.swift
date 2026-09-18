import Foundation

/// Reads an extract's water as rings, in three passes: the multipolygons say which ways
/// they are made of, the ways give their nodes, the nodes give the ground.
///
/// Relations come last in a file, so the ways a lake is built from cannot be told from
/// any other way until the relations have been read: hence a pass for them alone first.
enum WaterScan {
    static func bodies(in url: URL) throws -> WaterBodies {
        let lakes = try readMultipolygons(in: url)
        let ways = try readWays(in: url, members: lakes.memberIDs)
        let wanted = NodePlaces.wantedIDs(from: [ways.refs])
        guard !wanted.isEmpty else { return WaterBodies() }
        let places = try NodePlaces.gather(wanted, from: url)
        return assemble(lakes, ways, places)
    }

    // MARK: Pass one - the multipolygons

    struct Multipolygons {
        /// Per relation, its member ways and whether each is an island's edge.
        var members: [[(way: Int64, island: Bool)]] = []
        /// Every member way, sorted, for the way pass to look up.
        var memberIDs: [Int64] = []
    }

    private static func readMultipolygons(in url: URL) throws -> Multipolygons {
        var found = Multipolygons()
        try PBFReader(url: url).readInOrder(make: { Relations() }) { part in
            found.members.append(contentsOf: part.members)
            part.members.removeAll(keepingCapacity: true)
        }
        found.memberIDs = IDSort.unique(of: [found.members.flatMap { $0.map(\.way) }])
        return found
    }

    private struct Relations: OSMSink {
        let wantedParts: OSMParts = .relations
        var members: [[(way: Int64, island: Bool)]] = []

        mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                               memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                               keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                               block: OSMBlock) {
            var isMultipolygon = false, isWater = false
            for (key, value) in zip(keys, values) {
                let word = block.text(Int(key))
                if word == "type" {
                    isMultipolygon = block.text(Int(value)) == "multipolygon"
                } else if WaterBodies.isWater(key: word, value: block.text(Int(value))) {
                    isWater = true
                }
            }
            guard isMultipolygon, isWater else { return }
            var ways: [(way: Int64, island: Bool)] = []
            for ((kind, member), role) in zip(zip(memberKinds, memberIDs), memberRoles)
            where kind == wayKind {
                ways.append((member, block.text(Int(role)) == "inner"))
            }
            if !ways.isEmpty { members.append(ways) }
        }

        /// A relation member's kind: 0 node, 1 way, 2 relation.
        private let wayKind: Int32 = 1
    }

    // MARK: Pass two - the ways

    struct Ways {
        var ids: [Int64] = []
        /// Whether the way is water in its own right, rather than only a member.
        var standalone: [Bool] = []
        var starts: [Int32] = [0]
        var refs: [Int64] = []
    }

    private static func readWays(in url: URL, members: [Int64]) throws -> Ways {
        var found = Ways()
        try PBFReader(url: url).readInOrder(make: { WaySink(members: members) }) { part in
            found.ids.append(contentsOf: part.found.ids)
            found.standalone.append(contentsOf: part.found.standalone)
            let base = Int32(found.refs.count)
            found.refs.append(contentsOf: part.found.refs)
            for start in part.found.starts.dropFirst() { found.starts.append(base + start) }
            part.found = Ways()
        }
        return found
    }

    private struct WaySink: OSMSink {
        let wantedParts: OSMParts = .ways
        /// Sorted, shared by every lane and only read.
        let members: [Int64]
        var found = Ways()

        mutating func way(id: Int64, refs list: ArraySlice<Int64>,
                          keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {
            var water = false
            if list.count >= WaterBodies.fewestRingPoints, list.first == list.last {
                for (key, value) in zip(keys, values)
                where WaterBodies.isWater(key: block.text(Int(key)), value: block.text(Int(value))) {
                    water = true
                    break
                }
            }
            guard water || isMember(id) else { return }
            found.ids.append(id)
            found.standalone.append(water)
            found.refs.append(contentsOf: list)
            found.starts.append(Int32(found.refs.count))
        }

        private func isMember(_ id: Int64) -> Bool {
            var low = 0, high = members.count
            while low < high {
                let middle = (low + high) / 2
                if members[middle] < id { low = middle + 1 } else { high = middle }
            }
            return low < members.count && members[low] == id
        }
    }

    // MARK: Joining the passes

    private static func assemble(_ lakes: Multipolygons, _ ways: Ways,
                                 _ places: NodePlaces) -> WaterBodies {
        var bodies = WaterBodies()
        func ring(of chain: some Sequence<Int64>, island: Bool, standalone: Bool) -> WaterBodies.Ring {
            var points: [Float] = []
            for id in chain {
                guard let place = places.place(of: id) else { continue }
                points.append(Float(place.lat))
                points.append(Float(place.lon))
            }
            return WaterBodies.Ring(points: points, island: island, standalone: standalone)
        }

        var chainOf: [Int64: Range<Int>] = [:]
        for (at, id) in ways.ids.enumerated() {
            let range = Int(ways.starts[at])..<Int(ways.starts[at + 1])
            chainOf[id] = range
            if ways.standalone[at] {
                bodies.add(ring(of: ways.refs[range], island: false, standalone: true))
            }
        }
        for relation in lakes.members {
            for island in [false, true] {
                let pieces = relation.filter { $0.island == island }
                    .compactMap { chainOf[$0.way].map { Array(ways.refs[$0]) } }
                for chain in WaterBodies.closedChains(of: pieces) {
                    bodies.add(ring(of: chain, island: island, standalone: false))
                }
            }
        }
        return bodies
    }
}
