import Foundation

extension VenueScan {
    /// Second pass: the venue nodes in their own right, and the raw ids and places the
    /// ways of the first pass refer to.
    struct VenueNodes: OSMSink {
        let wantedParts: OSMParts = .nodes

        /// The venue keys as a lookup, since it is asked of every tag of every object.
        private static let keyRank: [String: Int] = Dictionary(
            uniqueKeysWithValues: VenueScan.keys.enumerated().map { ($1, $0) }
        )

        var nodes = BlockNodes()
        var venues: [(tag: String, x: Double, y: Double, name: String)] = []

        mutating func node(
            id: Int64,
            lat latitude: Double,
            lon longitude: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            nodes.node(id: id, lat: latitude, lon: longitude, tags: tags, block: block)

            // The key is chosen by the order of `VenueScan.keys`. Written without a
            // dictionary: this runs on every node of the extract.
            var bestKey = Int.max
            var bestValue = ""
            var name = ""
            var at = tags.startIndex
            while at + 1 < tags.endIndex {
                let key = block.text(Int(tags[at]))
                if let rank = Self.keyRank[key], rank < bestKey {
                    bestKey = rank
                    bestValue = block.text(Int(tags[at + 1]))
                } else if key == "name" {
                    name = block.text(Int(tags[at + 1]))
                }
                at += 2
            }
            if bestKey != Int.max {
                venues.append((VenueScan.keys[bestKey] + "=" + bestValue, longitude, latitude, name))
            }
        }

        mutating func clear() {
            nodes.clear()
            venues.removeAll(keepingCapacity: true)
        }
    }
}
