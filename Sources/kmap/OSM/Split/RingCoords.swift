import Foundation

extension TileSplitter {
    /// Where the ring nodes are: the wanted ids in order, a place beside each. Every
    /// reader fills it at once and no thread gathers what they found: a node is 1 slot,
    /// and a file holds a node once. `@unchecked Sendable` stands on that.
    final class RingCoords: @unchecked Sendable {
        /// Sorted, each once.
        let ids: [Int64]
        private let lat: UnsafeMutablePointer<Int32>
        private let lon: UnsafeMutablePointer<Int32>
        /// Every `fenceStride`-th id: a search settles its window here, in the cache,
        /// before it touches the table.
        private let fences: [Int64]
        private static let fenceStride = 64
        /// No latitude in map units: the mark of a node no file held.
        private static let missing = Int32.min

        init(ids: [Int64]) {
            self.ids = ids
            lat = .allocate(capacity: max(1, ids.count))
            lon = .allocate(capacity: max(1, ids.count))
            lat.initialize(repeating: Self.missing, count: max(1, ids.count))
            lon.initialize(repeating: 0, count: max(1, ids.count))
            fences = stride(from: 0, to: ids.count, by: Self.fenceStride).map { ids[$0] }
        }

        /// From a table of places, for the tests.
        convenience init(_ places: [Int64: (lat: Int32, lon: Int32)]) {
            self.init(ids: places.keys.sorted())
            for (rank, id) in ids.enumerated() {
                if let place = places[id] { put(place.lat, place.lon, at: rank) }
            }
        }

        deinit {
            lat.deallocate()
            lon.deallocate()
        }

        /// Records the node at `rank` of `ids`. The first to arrive stands: a node 2
        /// overlapping files share is taken from the earlier one.
        func put(_ latitude: Int32, _ longitude: Int32, at rank: Int) {
            guard lat[rank] == Self.missing else { return }
            lon[rank] = longitude
            lat[rank] = latitude
        }

        subscript(id: Int64) -> (lat: Int32, lon: Int32)? {
            guard let rank = rank(of: id), lat[rank] != Self.missing else { return nil }
            return (lat[rank], lon[rank])
        }

        private func rank(of id: Int64) -> Int? {
            // The last fence not past the id names the window it can be in.
            var lo = 0, hi = fences.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if fences[mid] <= id { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return nil }
            var left = (lo - 1) * Self.fenceStride
            var right = min(left + Self.fenceStride, ids.count)
            let end = right
            while left < right {
                let mid = (left + right) / 2
                if ids[mid] < id { left = mid + 1 } else { right = mid }
            }
            return left < end && ids[left] == id ? left : nil
        }
    }
}
