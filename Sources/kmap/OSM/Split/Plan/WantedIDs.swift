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
            if at < ids.count, ids[at] < id {
                // Galloping: the next wanted id is usually close, after a jump far away.
                // `ids[low]` is below the id; `high` is past the list or not below it.
                var low = at, step = 1, high = at + 1
                while high < ids.count, ids[high] < id {
                    low = high
                    step &*= 2
                    high = low + step
                }
                var first = low + 1, last = min(high, ids.count)
                while first < last {
                    let middle = (first + last) / 2
                    if ids[middle] < id { first = middle + 1 } else { last = middle }
                }
                at = first
            }
            return at < ids.count && ids[at] == id ? at : nil
        }
    }
}
