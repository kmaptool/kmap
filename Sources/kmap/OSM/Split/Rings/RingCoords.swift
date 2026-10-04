import CVector
import Foundation

extension TileSplitter {
    /// Where the ring nodes are: the wanted ids in order, a place beside each. Every
    /// reader fills it at once and no thread gathers what they found. A place goes into
    /// its slot in 1 atomic step, with the file it came from: `@unchecked Sendable`
    /// stands on that.
    ///
    /// A file holds a node once, and then nothing the readers do can disagree. A file
    /// that holds one twice, at 2 places, is noticed as a `conflict`, and the caller
    /// reads that file again in order, as `settle` takes it.
    final class RingCoords: @unchecked Sendable {
        /// Sorted, each once.
        let ids: [Int64]
        /// Per id, the file and the place packed in 1 word, or 0 where no file held it.
        private let slots: UnsafeMutablePointer<UInt64>
        /// Every `fenceStride`-th id: a search settles its window here, in the cache,
        /// before it touches the table.
        private let fences: [Int64]
        private static let fenceStride = 64
        /// Set by a node met twice in 1 file at 2 places.
        private let conflicting = Locked(false)

        init(ids: [Int64]) {
            self.ids = ids
            slots = .allocate(capacity: max(1, ids.count))
            slots.initialize(repeating: 0, count: max(1, ids.count))
            fences = stride(from: 0, to: ids.count, by: Self.fenceStride).map { ids[$0] }
        }

        /// From a table of places, for the tests.
        convenience init(_ places: [Int64: (lat: Int32, lon: Int32)]) {
            self.init(ids: places.keys.sorted())
            for (rank, id) in ids.enumerated() {
                if let place = places[id] { put(place.lat, place.lon, at: rank) }
            }
        }

        deinit { slots.deallocate() }

        // MARK: The packed word

        /// Map units reach 2^23 either way: 25 bits each once moved up by that, and the
        /// file's number above them, counted from 1 so that 0 is free.
        private static let offset: Int64 = 1 << 23
        private static let placeBits: UInt64 = 25
        private static let placeMask: UInt64 = (1 << 25) - 1
        /// The most files a split takes.
        static let fileLimit = (1 << 14) - 2

        static func pack(_ latitude: Int32, _ longitude: Int32, file: Int) -> UInt64 {
            assert(abs(Int64(latitude)) <= offset && abs(Int64(longitude)) <= offset, "outside map units")
            assert(file >= 0 && file <= fileLimit, "too many files")
            let la = UInt64(Int64(latitude) + offset), lo = UInt64(Int64(longitude) + offset)
            return UInt64(file + 1) << (2 * placeBits) | la << placeBits | lo
        }

        static func unpack(_ word: UInt64) -> (lat: Int32, lon: Int32, file: Int) {
            let la = Int64((word >> placeBits) & placeMask) - offset
            let lo = Int64(word & placeMask) - offset
            return (Int32(la), Int32(lo), Int(word >> (2 * placeBits)) - 1)
        }

        // MARK: Filling

        /// Records the node at `rank` of `ids`, as read from `file` by any of the readers.
        /// The first to arrive stands: a node 2 overlapping files share is taken from the
        /// earlier one, which is read first.
        func put(_ latitude: Int32, _ longitude: Int32, at rank: Int, file: Int = 0) {
            let word = Self.pack(latitude, longitude, file: file)
            let held = kmap_claim_slot(slots + rank, word)
            guard held != 0, held != word else { return }
            // The same file had it at another place: which copy stands depends on which
            // reader came first, so the file is read again in order.
            if Self.unpack(held).file == file { conflicting.withLock { $0 = true } }
        }

        /// Whether a file held a node twice at 2 places since the last asking.
        func takeConflict() -> Bool {
            conflicting.withLock { held in
                let was = held
                held = false
                return was
            }
        }

        /// Empties every slot `file` filled, before the file is read again.
        func forget(file: Int) {
            for rank in 0..<ids.count where slots[rank] != 0 && Self.unpack(slots[rank]).file == file {
                slots[rank] = 0
            }
        }

        /// Records a node as 1 reader taking `file` in order does, as kmap did before the
        /// readers filled the table themselves: with 1 input the last copy stands, with
        /// several the first.
        func settle(_ latitude: Int32, _ longitude: Int32, at rank: Int, file: Int, lastStands: Bool) {
            guard slots[rank] == 0 || (lastStands && Self.unpack(slots[rank]).file == file) else { return }
            slots[rank] = Self.pack(latitude, longitude, file: file)
        }

        subscript(id: Int64) -> (lat: Int32, lon: Int32)? {
            guard let rank = rank(of: id), slots[rank] != 0 else { return nil }
            let place = Self.unpack(slots[rank])
            return (place.lat, place.lon)
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
