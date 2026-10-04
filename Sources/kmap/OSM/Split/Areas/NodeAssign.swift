import Foundation

extension TileSplitter {
    /// One block's mapping of node to tiles, worked out on any core. A shared-line node's
    /// set is named here and interned when the block is applied.
    struct NodeAssign: OSMSink {
        let wantedParts: OSMParts = .nodes

        let lookup: AreaLookup
        var ids: [Int64] = []
        var values: [UInt16] = []
        /// Position in `values` to the set it stands for, for the few on a shared line.
        var shared: [(at: Int, areas: AreaLookup.Hits)] = []
        /// Position in `values` to the pair it stands for, for a node in a neighbour's
        /// shape band: where it lives, and where a shape through it must be delivered.
        /// The block's pairs are listed once each, in the order first met, and interned
        /// in that order when applied.
        var banded: [(at: Int, band: Int)] = []
        var bands: [NodeAreas.BandKey] = []
        private var bandIndex: [NodeAreas.BandKey: Int] = [:]
        private var lastBand = 0

        init(lookup: AreaLookup) {
            self.lookup = lookup
        }

        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            let mapLat = TileSplitter.mapUnits(lat)
            let mapLon = TileSplitter.mapUnits(lon)
            let hits = lookup.areas(lat: mapLat, lon: mapLon)
            ids.append(id)

            // Only a node that belongs somewhere can widen; one outside every tile is
            // beyond the map.
            if hits.count > 0 {
                let shape = lookup.shapeAreas(lat: mapLat, lon: mapLon, widening: hits)
                if shape.count > hits.count {
                    let band = band(of: NodeAreas.BandKey(strict: hits.inOrder, shape: shape.inOrder))
                    banded.append((values.count, band))
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

        /// The block's number for a pair of answers, the pair listed if it is new.
        private mutating func band(of key: NodeAreas.BandKey) -> Int {
            // Neighbouring nodes mostly share a pair.
            if lastBand < bands.count, bands[lastBand] == key { return lastBand }
            if let known = bandIndex[key] {
                lastBand = known
            } else {
                bands.append(key)
                lastBand = bands.count - 1
                bandIndex[key] = lastBand
            }
            return lastBand
        }

        mutating func clear() {
            ids.removeAll(keepingCapacity: true)
            values.removeAll(keepingCapacity: true)
            shared.removeAll(keepingCapacity: true)
            banded.removeAll(keepingCapacity: true)
            bands.removeAll(keepingCapacity: true)
            bandIndex.removeAll(keepingCapacity: true)
            lastBand = 0
        }
    }
}
