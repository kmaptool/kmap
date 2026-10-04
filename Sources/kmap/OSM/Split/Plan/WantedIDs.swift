import Foundation

extension TileSplitter {
    /// Ids wanted by a pass, sorted and walked in step with the file rather than hashed
    /// once per object. Both lists ascend, so it is a merge.
    struct WantedIDs {
        private let ids: [Int64]
        private var at = 0
        private var lastID = Int64.min

        init(_ wanted: Set<Int64>) {
            ids = wanted.sorted()
        }

        /// From ids already in order and unique.
        init(sorted: [Int64]) {
            ids = sorted
        }

        var isEmpty: Bool { ids.isEmpty }

        mutating func wants(_ id: Int64) -> Bool { rank(of: id) != nil }

        /// Where `id` stands among the wanted ids, or nil if it is not one of them.
        mutating func rank(of id: Int64) -> Int? {
            if id < lastID { at = 0 }  // a worker starting its own run of blocks
            lastID = id
            while at < ids.count, ids[at] < id { at += 1 }
            return at < ids.count && ids[at] == id ? at : nil
        }
    }
}
