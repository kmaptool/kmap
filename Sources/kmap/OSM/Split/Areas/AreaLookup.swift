import Foundation

/// Which tile, or tiles, a point falls in.
///
/// A grid over the map at a fixed cell size holding the index of the tile that owns each
/// cell, two bytes per cell, so a lookup is an array index rather than a walk over the
/// rectangles.
extension TileSplitter {
    struct AreaLookup {
        /// No area covers this cell.
        static let none = UInt16.max

        private var grid: [UInt16] = []
        /// Per cell: its 3x3 neighbourhood names 1 value throughout, so no neighbour can
        /// widen a shape answer there.
        private var plain: [Bool] = []
        private var rects: [Area] = []
        private var shapeOverlap: Int32 = TileSplitter.shapeClipOverlap
        private var minLatCell: Int32 = 0, minLonCell: Int32 = 0
        private var rows = 0, cols = 0

        init(areas: [Area], shapeOverlap: Int32 = TileSplitter.shapeClipOverlap) {
            self.shapeOverlap = shapeOverlap
            guard !areas.isEmpty else { return }
            var minLat = Int32.max, maxLat = Int32.min
            var minLon = Int32.max, maxLon = Int32.min
            for area in areas {
                minLat = min(minLat, area.minLat >> TileSplitter.gridShift)
                maxLat = max(maxLat, (area.maxLat >> TileSplitter.gridShift) - 1)
                minLon = min(minLon, area.minLon >> TileSplitter.gridShift)
                maxLon = max(maxLon, (area.maxLon >> TileSplitter.gridShift) - 1)
            }
            guard minLat <= maxLat, minLon <= maxLon else { return }
            rects = areas
            minLatCell = minLat
            minLonCell = minLon
            rows = Int(maxLat - minLat) + 1
            cols = Int(maxLon - minLon) + 1
            fillGrid()
            markPlainCells()
        }

        /// Every cell names the area covering it.
        private mutating func fillGrid() {
            grid = [UInt16](repeating: Self.none, count: rows * cols)
            for (index, area) in rects.enumerated() {
                var lat = area.minLat >> TileSplitter.gridShift
                while lat < area.maxLat >> TileSplitter.gridShift {
                    let row = Int(lat - minLatCell) * cols
                    var lon = area.minLon >> TileSplitter.gridShift
                    while lon < area.maxLon >> TileSplitter.gridShift {
                        grid[row + Int(lon - minLonCell)] = UInt16(index)
                        lon += 1
                    }
                    lat += 1
                }
            }
        }

        private mutating func markPlainCells() {
            plain = [Bool](repeating: false, count: rows * cols)
            for row in 0..<rows {
                for column in 0..<cols { plain[row * cols + column] = isPlain(row: row, column: column) }
            }
        }

        /// Whether the cell and the 8 round it name 1 value, beyond the grid counting as none.
        private func isPlain(row: Int, column: Int) -> Bool {
            let here = grid[row * cols + column]
            for dRow in -1...1 {
                for dColumn in -1...1 {
                    let r = row + dRow, c = column + dColumn
                    let near = r >= 0 && r < rows && c >= 0 && c < cols ? grid[r * cols + c] : Self.none
                    if near != here { return false }
                }
            }
            return true
        }

        private func area(latCell: Int32, lonCell: Int32) -> UInt16 {
            let row = Int(latCell - minLatCell)
            let column = Int(lonCell - minLonCell)
            guard row >= 0, row < rows, column >= 0, column < cols else { return Self.none }
            return grid[row * cols + column]
        }

        /// Every area holding this point: one for an interior point, both neighbours for a
        /// point exactly on a shared edge, all four at a corner. A way ending exactly on the
        /// line therefore spans two tiles and is written whole to each.
        func areas(lat: Int32, lon: Int32) -> Hits {
            let latCell = lat >> TileSplitter.gridShift
            let lonCell = lon >> TileSplitter.gridShift
            var hits = Hits()
            let here = area(latCell: latCell, lonCell: lonCell)
            if here != Self.none { hits.add(here) }

            let onLatEdge = lat & TileSplitter.gridMask == 0
            let onLonEdge = lon & TileSplitter.gridMask == 0
            guard onLatEdge || onLonEdge else { return hits }

            if onLatEdge {
                let below = area(latCell: latCell - 1, lonCell: lonCell)
                if below != Self.none { hits.add(below) }
            }
            if onLonEdge {
                let west = area(latCell: latCell, lonCell: lonCell - 1)
                if west != Self.none { hits.add(west) }
            }
            if onLatEdge && onLonEdge {
                let corner = area(latCell: latCell - 1, lonCell: lonCell - 1)
                if corner != Self.none { hits.add(corner) }
            }
            return hits
        }

        /// The areas above, plus every neighbour whose ground comes within `shapeClipOverlap`
        /// of the point, where a shape must also be delivered: a tile paints shapes past its
        /// own frame and can only paint what it was given. Shapes only; lines clip exactly.
        ///
        /// The overlap is at most one cell wide, so the 3×3 neighbourhood bounds the search
        /// and the rectangle test decides.
        func shapeAreas(lat: Int32, lon: Int32) -> Hits {
            shapeAreas(lat: lat, lon: lon, widening: areas(lat: lat, lon: lon))
        }

        /// The same, given what `areas` answered for the point.
        func shapeAreas(lat: Int32, lon: Int32, widening strict: Hits) -> Hits {
            var hits = strict
            let latCell = lat >> TileSplitter.gridShift
            let lonCell = lon >> TileSplitter.gridShift
            guard shapeOverlap > 0 else { return hits }
            let row = Int(latCell - minLatCell)
            let column = Int(lonCell - minLonCell)
            if row >= 0, row < rows, column >= 0, column < cols, plain[row * cols + column] { return hits }
            let margin = shapeOverlap
            for dLat in Int32(-1)...1 {
                for dLon in Int32(-1)...1 {
                    let near = area(latCell: latCell + dLat, lonCell: lonCell + dLon)
                    guard near != Self.none, !hits.contains(near) else { continue }
                    let rect = rects[Int(near)]
                    guard lat >= rect.minLat - margin, lat < rect.maxLat + margin,
                        lon >= rect.minLon - margin, lon < rect.maxLon + margin
                    else { continue }
                    hits.add(near)
                }
            }
            return hits
        }
    }
}
