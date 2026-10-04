import Foundation

extension TileSplitter {
    struct WayRefs: OSMSink {
        let wantedParts: OSMParts = .ways

        var wanted: WantedIDs
        var refs: [Int64: [Int64]] = [:]
        mutating func way(
            id: Int64,
            refs list: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            if wanted.wants(id) { refs[id] = list.exactly }
        }
    }
}
