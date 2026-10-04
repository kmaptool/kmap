import Foundation

/// One block's nodes, gathered on whichever core decoded it.
struct BlockNodes: OSMSink {
    let wantedParts: OSMParts = .nodes

    var ids: [Int64] = []
    var lat: [Double] = []
    var lon: [Double] = []

    mutating func node(
        id: Int64,
        lat latitude: Double,
        lon longitude: Double,
        tags: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        ids.append(id)
        lat.append(latitude)
        lon.append(longitude)
    }

    mutating func clear() {
        ids.removeAll(keepingCapacity: true)
        lat.removeAll(keepingCapacity: true)
        lon.removeAll(keepingCapacity: true)
    }
}
