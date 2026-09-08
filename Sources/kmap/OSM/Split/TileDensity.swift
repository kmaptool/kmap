import Foundation

/// How many nodes fall in each cell of the map, and where to cut it. Tiles are not a grid:
/// a dense area wants small ones and an empty one wants a single large tile, so nodes are
/// counted onto a coarse grid and the map is cut where the counts say — through the widest
/// gap where there is one, and by share where there is not.
extension TileSplitter {
    struct Density: OSMSink {
        let wantedParts: OSMParts = .nodes

        /// Counts per cell: a flat grid over the ground the inputs declare they cover, which
        /// every counted node is inside by construction. Four bytes a cell, and merging is
        /// an addition. Falls back to a dictionary where there is no declared box to size it.
        private var grid: [Int32] = []
        private var gridRows = 0, gridCols = 0
        private var gridLat: Int32 = 0, gridLon: Int32 = 0
        private var counts: [Int64: Int32] = [:]
        var total = 0
        var minLatCell = Int32.max, maxLatCell = Int32.min
        var minLonCell = Int32.max, maxLonCell = Int32.min
        /// Cells outside every window are fringe: counted nowhere, covered by no tile.
        var clips: [(minLatCell: Int32, minLonCell: Int32,
                     maxLatCell: Int32, maxLonCell: Int32)] = []

        /// Row-major running totals over the occupied box, one row and column of zeroes
        /// ahead of it so a rectangle needs no special case at the edges.
        private var sums: [Int64] = []
        private var rows = 0, cols = 0

        static func key(_ latCell: Int32, _ lonCell: Int32) -> Int64 {
            (Int64(latCell) << 32) | Int64(UInt32(bitPattern: lonCell))
        }

        /// Lays out the grid over everything the clip windows cover. Called once the
        /// windows are known and before anything is counted.
        mutating func prepare() {
            guard !clips.isEmpty else { return }
            var minLat = Int32.max, maxLat = Int32.min
            var minLon = Int32.max, maxLon = Int32.min
            for clip in clips {
                minLat = min(minLat, clip.minLatCell); maxLat = max(maxLat, clip.maxLatCell)
                minLon = min(minLon, clip.minLonCell); maxLon = max(maxLon, clip.maxLonCell)
            }
            guard minLat <= maxLat, minLon <= maxLon else { return }
            let rows = Int(maxLat - minLat) + 1
            let cols = Int(maxLon - minLon) + 1
            // A box so large the grid would outweigh what it counts: keep the dictionary.
            guard rows > 0, cols > 0, rows * cols <= 64 << 20 else { return }
            gridLat = minLat
            gridLon = minLon
            gridRows = rows
            gridCols = cols
            grid = [Int32](repeating: 0, count: rows * cols)
        }

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            let latCell = TileSplitter.mapUnits(lat) >> TileSplitter.gridShift
            let lonCell = TileSplitter.mapUnits(lon) >> TileSplitter.gridShift
            if !clips.isEmpty, !clips.contains(where: {
                latCell >= $0.minLatCell && latCell < $0.maxLatCell
                    && lonCell >= $0.minLonCell && lonCell < $0.maxLonCell
            }) {
                return
            }
            if !grid.isEmpty {
                let row = Int(latCell - gridLat), column = Int(lonCell - gridLon)
                if row >= 0, row < gridRows, column >= 0, column < gridCols {
                    grid[row * gridCols + column] += 1
                }
            } else {
                counts[Self.key(latCell, lonCell), default: 0] += 1
            }
            total += 1
            minLatCell = min(minLatCell, latCell); maxLatCell = max(maxLatCell, latCell)
            minLonCell = min(minLonCell, lonCell); maxLonCell = max(maxLonCell, lonCell)
        }

        /// Takes in another worker's counts. The pass is commutative — a cell's tally is a
        /// sum, the bounds a min and a max — so the file can be counted on every core.
        mutating func merge(_ other: Density) {
            if !grid.isEmpty, other.grid.count == grid.count {
                for i in 0..<grid.count { grid[i] &+= other.grid[i] }
            } else {
                for (key, value) in other.counts { counts[key, default: 0] += value }
            }
            total += other.total
            minLatCell = min(minLatCell, other.minLatCell)
            maxLatCell = max(maxLatCell, other.maxLatCell)
            minLonCell = min(minLonCell, other.minLonCell)
            maxLonCell = max(maxLonCell, other.maxLonCell)
        }

        /// Turns the counted cells into running totals. Nothing may be counted afterwards,
        /// and nothing may be asked before.
        mutating func seal() {
            guard total > 0 else { return }
            rows = Int(maxLatCell - minLatCell) + 1
            cols = Int(maxLonCell - minLonCell) + 1
            sums = [Int64](repeating: 0, count: (rows + 1) * (cols + 1))
            if !grid.isEmpty {
                for row in 0..<gridRows {
                    for column in 0..<gridCols {
                        let count = grid[row * gridCols + column]
                        guard count > 0 else { continue }
                        let atRow = Int(Int32(row) + gridLat - minLatCell) + 1
                        let atCol = Int(Int32(column) + gridLon - minLonCell) + 1
                        sums[atRow * (cols + 1) + atCol] = Int64(count)
                    }
                }
                grid = []
            }
            for (key, value) in counts {
                let latCell = Int32(truncatingIfNeeded: key >> 32)
                let lonCell = Int32(bitPattern: UInt32(truncatingIfNeeded: key))
                let row = Int(latCell - minLatCell) + 1
                let column = Int(lonCell - minLonCell) + 1
                sums[row * (cols + 1) + column] = Int64(value)
            }
            for row in 1...rows {
                for column in 1...cols {
                    sums[row * (cols + 1) + column] +=
                        sums[(row - 1) * (cols + 1) + column]
                        + sums[row * (cols + 1) + column - 1]
                        - sums[(row - 1) * (cols + 1) + column - 1]
                }
            }
            counts.removeAll(keepingCapacity: false)
        }

        /// A rectangle in grid cells, half-open.
        struct Cells {
            var minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32
            var area: Area {
                Area(minLat: minLat << TileSplitter.gridShift, minLon: minLon << TileSplitter.gridShift,
                     maxLat: maxLat << TileSplitter.gridShift, maxLon: maxLon << TileSplitter.gridShift)
            }
        }

        func boundsCells() -> Cells {
            Cells(minLat: minLatCell, minLon: minLonCell,
                  maxLat: maxLatCell + 1, maxLon: maxLonCell + 1)
        }

        /// Rows and columns of the table a rectangle covers, clipped to what was counted.
        private func window(_ rect: Cells) -> (top: Int, left: Int, bottom: Int, right: Int)? {
            guard rows > 0, cols > 0 else { return nil }
            let top = max(0, min(rows, Int(rect.minLat - minLatCell)))
            let bottom = max(0, min(rows, Int(rect.maxLat - minLatCell)))
            let left = max(0, min(cols, Int(rect.minLon - minLonCell)))
            let right = max(0, min(cols, Int(rect.maxLon - minLonCell)))
            guard bottom > top, right > left else { return nil }
            return (top, left, bottom, right)
        }

        func count(_ rect: Cells) -> Int {
            guard let w = window(rect) else { return 0 }
            let stride = cols + 1
            let total = sums[w.bottom * stride + w.right]
                - sums[w.top * stride + w.right]
                - sums[w.bottom * stride + w.left]
                + sums[w.top * stride + w.left]
            return Int(total)
        }

        /// One row of cells within a rectangle, and one column.
        private func rowCount(_ latCell: Int32, in rect: Cells) -> Int {
            count(Cells(minLat: latCell, minLon: rect.minLon,
                        maxLat: latCell + 1, maxLon: rect.maxLon))
        }

        private func columnCount(_ lonCell: Int32, in rect: Cells) -> Int {
            count(Cells(minLat: rect.minLat, minLon: lonCell,
                        maxLat: rect.maxLat, maxLon: lonCell + 1))
        }

        /// Cuts through the widest run of empty grid lines, where one is wide enough to be
        /// a gap rather than a park.
        func splitAcrossGap(_ rect: Cells) -> (Cells, Cells)? {
            for alongLat in [true, false] {
                let lo = alongLat ? rect.minLat : rect.minLon
                let hi = alongLat ? rect.maxLat : rect.maxLon
                guard hi - lo > 2 else { continue }
                var bestStart = Int32(0), bestRun = Int32(0)
                var run = Int32(0)
                for line in lo..<hi {
                    let occupied = alongLat ? rowCount(line, in: rect)
                                            : columnCount(line, in: rect)
                    if occupied == 0 {
                        run += 1
                        if run > bestRun { bestRun = run; bestStart = line - run + 1 }
                    } else {
                        run = 0
                    }
                }
                // Ignore a gap that runs off either end: that is just margin, not a divide.
                guard bestRun >= Self.gapCells, bestStart > lo,
                      bestStart + bestRun < hi else { continue }
                let cut = bestStart + bestRun / 2
                return Self.cut(rect, at: cut, alongLat: alongLat)
            }
            return nil
        }

        /// How many empty grid lines make a divide rather than a park. Sixteen cells of
        /// 2048 map units is about 35 km.
        private static let gapCells: Int32 = 16

        /// Splits along the longer axis, the first part taking `share` of the nodes.
        func split(_ rect: Cells, share: Double) -> (Cells, Cells)? {
            let tall = (rect.maxLat - rect.minLat) >= (rect.maxLon - rect.minLon)
            let span = tall ? rect.maxLat - rect.minLat : rect.maxLon - rect.minLon
            guard span > 1 else {
                // Try the other axis before giving up.
                let other = tall ? rect.maxLon - rect.minLon : rect.maxLat - rect.minLat
                guard other > 1 else { return nil }
                return splitAxis(rect, alongLat: !tall, share: share)
            }
            return splitAxis(rect, alongLat: tall, share: share)
        }

        private func splitAxis(_ rect: Cells, alongLat: Bool, share: Double) -> (Cells, Cells)? {
            let lo = alongLat ? rect.minLat : rect.minLon
            let hi = alongLat ? rect.maxLat : rect.maxLon
            guard hi - lo > 1 else { return nil }
            let whole = count(rect)
            let wanted = Int(Double(whole) * share)
            var running = 0
            var cut = lo + 1
            for line in lo..<hi {
                running += alongLat ? rowCount(line, in: rect) : columnCount(line, in: rect)
                if running >= wanted {
                    cut = line + 1
                    break
                }
            }
            cut = max(lo + 1, min(hi - 1, cut))
            return Self.cut(rect, at: cut, alongLat: alongLat)
        }

        /// The two halves of a rectangle, lower first on either axis. Which half comes
        /// first decides which one `share` was about, so both axes answer the same way.
        private static func cut(_ rect: Cells, at line: Int32,
                                alongLat: Bool) -> (Cells, Cells) {
            if alongLat {
                return (Cells(minLat: rect.minLat, minLon: rect.minLon,
                              maxLat: line, maxLon: rect.maxLon),
                        Cells(minLat: line, minLon: rect.minLon,
                              maxLat: rect.maxLat, maxLon: rect.maxLon))
            }
            return (Cells(minLat: rect.minLat, minLon: rect.minLon,
                          maxLat: rect.maxLat, maxLon: line),
                    Cells(minLat: rect.minLat, minLon: line,
                          maxLat: rect.maxLat, maxLon: rect.maxLon))
        }

        /// Shrinks an area to the grid cells that actually hold nodes.
        func trim(_ area: Area) -> Area {
            let rect = Cells(minLat: area.minLat >> TileSplitter.gridShift, minLon: area.minLon >> TileSplitter.gridShift,
                             maxLat: area.maxLat >> TileSplitter.gridShift, maxLon: area.maxLon >> TileSplitter.gridShift)
            guard count(rect) > 0 else { return area }
            var minLat = rect.minLat, maxLat = rect.maxLat - 1
            while minLat < maxLat, rowCount(minLat, in: rect) == 0 { minLat += 1 }
            while maxLat > minLat, rowCount(maxLat, in: rect) == 0 { maxLat -= 1 }
            var minLon = rect.minLon, maxLon = rect.maxLon - 1
            while minLon < maxLon, columnCount(minLon, in: rect) == 0 { minLon += 1 }
            while maxLon > minLon, columnCount(maxLon, in: rect) == 0 { maxLon -= 1 }
            return Area(minLat: minLat << TileSplitter.gridShift, minLon: minLon << TileSplitter.gridShift,
                        maxLat: (maxLat + 1) << TileSplitter.gridShift, maxLon: (maxLon + 1) << TileSplitter.gridShift)
        }
    }
}
