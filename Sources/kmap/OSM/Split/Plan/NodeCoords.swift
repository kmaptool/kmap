import Foundation

extension TileSplitter {
    struct NodeCoords: OSMSink {
        let wantedParts: OSMParts = .nodes

        var wanted: WantedIDs
        /// Every wanted node's place, written straight into its slot from whichever
        /// reader meets the node.
        let coords: RingCoords
        /// Which input this is, counted from 0.
        let file: Int
        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            if let rank = wanted.rank(of: id) {
                coords.put(TileSplitter.mapUnits(lat), TileSplitter.mapUnits(lon), at: rank, file: file)
            }
        }
    }

    /// The same nodes, gathered by 1 reader of a block for a caller that takes the blocks
    /// in the file's order: a file read again because it holds a node twice.
    struct NodeCoordsInOrder: OSMSink {
        let wantedParts: OSMParts = .nodes

        var wanted: WantedIDs
        var found: [(rank: Int, lat: Int32, lon: Int32)] = []
        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            if let rank = wanted.rank(of: id) {
                found.append((rank, TileSplitter.mapUnits(lat), TileSplitter.mapUnits(lon)))
            }
        }
    }
}
