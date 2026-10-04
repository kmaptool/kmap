import Foundation

extension TileSplitter {
    struct NodeCoords: OSMSink {
        let wantedParts: OSMParts = .nodes

        var wanted: WantedIDs
        /// Every wanted node's place, written straight into its slot from whichever
        /// reader meets the node.
        let coords: RingCoords
        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            if let rank = wanted.rank(of: id) {
                coords.put(TileSplitter.mapUnits(lat), TileSplitter.mapUnits(lon), at: rank)
            }
        }
    }
}
