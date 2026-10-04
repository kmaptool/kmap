import Foundation

extension GroundIndex {
    struct Builder: OSMSink {
        let frame: BBox
        var wantedParts: OSMParts { .all }

        // Node ids arrive ascending in a PBF, so parallel arrays + binary search
        // replace a five-million-entry dictionary. A file that breaks the order is
        // sorted once, before the first way asks.
        var coordIDs: [Int64] = []
        var coordCells: [UInt64] = []
        var ascending = true
        var nodes: [IndexedNode] = []
        var nodesByCell: [UInt64: [Int32]] = [:]
        var ways: [IndexedWay] = []
        var gramPairs: [(gram: UInt64, slot: Int32)] = []
        var relationTags: [Int64: [String: String]] = [:]
        /// The distinct multipolygons a bare way is an outer of.
        var bareOuterOf: [Int64: Set<Int64>] = [:]
        /// The cells of every bare way in frame, until the relations have been read.
        var bareCells: [Int64: [UInt64]] = [:]
        var inner: Set<Int64> = []

        init(frame: BBox) { self.frame = frame }

        private func cell(of ref: Int64) -> UInt64? {
            var low = 0, high = coordIDs.count
            while low < high {
                let mid = (low + high) / 2
                if coordIDs[mid] < ref { low = mid + 1 } else { high = mid }
            }
            guard low < coordIDs.count, coordIDs[low] == ref else { return nil }
            return coordCells[low]
        }

        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            guard frame.contains(lat: lat, lon: lon) else { return }
            let cell = GarminGrid.cell(lat: lat, lon: lon)
            if let last = coordIDs.last, id <= last { ascending = false }
            coordIDs.append(id)
            coordCells.append(cell)
            guard !tags.isEmpty else { return }
            let slot = Int32(nodes.count)
            nodes.append(IndexedNode(id: id, cell: cell, tags: decode(pairs: tags, block)))
            nodesByCell[cell, default: []].append(slot)
        }

        mutating func way(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            if !ascending { sortCoords() }
            var cells: [UInt64] = []
            cells.reserveCapacity(refs.count)
            for ref in refs {
                guard let cell = cell(of: ref) else { continue }
                cells.append(cell)
            }
            guard cells.count >= 2 else { return }
            let tags = decode(keys: keys, values: values, block)
            if tags.isEmpty {
                // Not indexed yet, but kept: a multipolygon may give it meaning.
                bareCells[id] = cells
                return
            }
            appendWay(id: id, cells: cells, tags: tags)
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
            let tags = decode(keys: keys, values: values, block)
            let kind = tags[DefaultRuleBook.relationTypeKey]
            guard kind == GroundIndex.multipolygonType || kind == GroundIndex.boundaryType
            else { return }
            relationTags[id] = tags
            let kinds = memberKinds.exactly, ids = memberIDs.exactly, roles = memberRoles.exactly
            // Three packed fields the decoder does not reconcile: the shortest bounds them.
            for i in 0..<min(kinds.count, ids.count, roles.count) where kinds[i] == 1 {
                let role = block.text(Int(roles[i]))
                if role == GroundIndex.innerRole { inner.insert(ids[i]); continue }
                guard role.isEmpty || role == GroundIndex.outerRole else { continue }
                if bareCells[ids[i]] != nil {
                    bareOuterOf[ids[i], default: []].insert(id)
                }
            }
        }

        private mutating func sortCoords() {
            let order = coordIDs.indices.sorted { coordIDs[$0] < coordIDs[$1] }
            coordIDs = order.map { coordIDs[$0] }
            coordCells = order.map { coordCells[$0] }
            ascending = true
        }

        mutating func appendWay(id: Int64, cells: [UInt64], tags: [String: String]) {
            let slot = Int32(ways.count)
            ways.append(IndexedWay(id: id, cells: cells, tags: tags))
            for gram in GarminGrid.grams(of: cells) {
                gramPairs.append((gram, slot))
            }
            if cells.count == 2 { gramPairs.append((GarminGrid.edge(cells[0], cells[1]), slot)) }
        }

        private func decode(pairs: ArraySlice<Int32>, _ block: OSMBlock) -> [String: String] {
            var out: [String: String] = [:]
            var i = pairs.startIndex
            while i + 1 < pairs.endIndex {
                out[block.text(Int(pairs[i]))] = block.text(Int(pairs[i + 1]))
                i += 2
            }
            return out
        }

        private func decode(
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            _ block: OSMBlock
        ) -> [String: String] {
            var out: [String: String] = [:]
            for (k, v) in zip(keys, values) {
                out[block.text(Int(k))] = block.text(Int(v))
            }
            return out
        }
    }
}
