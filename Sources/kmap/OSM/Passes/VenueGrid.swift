import Foundation

/// The spatial index one tag's venue areas are filed in — see `VenueScan.markOne`.
extension VenueScan {
    /// The areas of one tag, filed by the ground they cover.
    ///
    /// One grid per size, boxes running from a shed to a national park: side 2^k of the
    /// smallest box, each area filed at the level where it spans no more than two cells
    /// either way, and a query asking each level for the cell holding the point. Cells are
    /// sorted keys rather than a table, the covered ground being mostly empty.
    struct Grid {
        /// Below this a group is walked whole -- indexing it costs more than it saves.
        static let leastWorthIndexing = 64
        /// Levels are doublings, so this reaches 16 million times the smallest box.
        static let mostLevels = 24

        private var x0 = 0.0, y0 = 0.0
        private var base = 0.0
        /// Per level: the occupied cell keys in order, where each one's items start, and
        /// the items themselves.
        private var keys: [[Int64]] = []
        private var starts: [[Int32]] = []
        private var items: [[Int32]] = []
        /// Set when the group is too small to index: every query offers everything.
        private var all: [Int32] = []

        init(_ group: [Area]) {
            guard group.count >= Self.leastWorthIndexing else {
                all = Array(0..<Int32(group.count))
                return
            }
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            var smallest = Double.infinity
            for area in group {
                minX = min(minX, area.box.x0); minY = min(minY, area.box.y0)
                maxX = max(maxX, area.box.x1); maxY = max(maxY, area.box.y1)
                let extent = max(area.box.x1 - area.box.x0, area.box.y1 - area.box.y0)
                if extent > 0 { smallest = min(smallest, extent) }
            }
            let span = max(maxX - minX, maxY - minY)
            guard span > 0, span.isFinite else {
                all = Array(0..<Int32(group.count))
                return
            }
            // A degenerate box -- a ring folded onto a line -- would otherwise set the base
            // at nothing and ask for every level there is.
            if !smallest.isFinite || smallest <= 0 { smallest = span }
            base = max(smallest, span / Double(1 << Self.mostLevels))
            x0 = minX; y0 = minY

            let levels = min(Self.mostLevels,
                             max(1, Int((log2(span / base)).rounded(.up)) + 1))
            var filed = [[(key: Int64, index: Int32)]](repeating: [], count: levels)
            for (index, area) in group.enumerated() {
                let extent = max(area.box.x1 - area.box.x0, area.box.y1 - area.box.y0)
                let level = min(levels - 1,
                                max(0, Int((log2(max(extent, base) / base)).rounded(.up))))
                let side = base * Double(1 << level)
                let c0 = column(area.box.x0, side), r0 = row(area.box.y0, side)
                let c1 = column(area.box.x1, side), r1 = row(area.box.y1, side)
                for r in r0...r1 {
                    for c in c0...c1 { filed[level].append((r << 32 | (c & 0xFFFF_FFFF), Int32(index))) }
                }
            }

            keys = []; starts = []; items = []
            for var level in filed {
                level.sort { $0.key == $1.key ? $0.index < $1.index : $0.key < $1.key }
                var levelKeys: [Int64] = []
                var levelStarts: [Int32] = []
                var levelItems: [Int32] = []
                levelItems.reserveCapacity(level.count)
                for entry in level {
                    if levelKeys.last != entry.key {
                        levelKeys.append(entry.key)
                        levelStarts.append(Int32(levelItems.count))
                    }
                    levelItems.append(entry.index)
                }
                levelStarts.append(Int32(levelItems.count))
                keys.append(levelKeys); starts.append(levelStarts); items.append(levelItems)
            }
        }

        private func column(_ x: Double, _ side: Double) -> Int64 { Int64(((x - x0) / side).rounded(.down)) }
        private func row(_ y: Double, _ side: Double) -> Int64 { Int64(((y - y0) / side).rounded(.down)) }

        /// Every area that could cover this point. Offered in no particular order: both
        /// callers gather into a set, which does not care.
        func candidates(at point: (x: Double, y: Double), _ body: (Int) -> Void) {
            if !all.isEmpty {
                for index in all { body(Int(index)) }
                return
            }
            for level in 0..<keys.count where !keys[level].isEmpty {
                let side = base * Double(1 << level)
                let key = row(point.y, side) << 32 | (column(point.x, side) & 0xFFFF_FFFF)
                var low = 0, high = keys[level].count - 1
                while low <= high {
                    let mid = (low + high) / 2
                    if keys[level][mid] == key {
                        for at in Int(starts[level][mid])..<Int(starts[level][mid + 1]) {
                            body(Int(items[level][at]))
                        }
                        break
                    }
                    if keys[level][mid] < key { low = mid + 1 } else { high = mid - 1 }
                }
            }
        }
    }
}
