import Foundation

/// Traces contour lines across a .hgt tile by marching squares.
///
/// A crossing always sits on one edge of one cell, so it is identified by that edge rather
/// than by its coordinates: segments meet when their edge keys are equal, an integer
/// comparison. Coordinates are resolved once, at the end.
struct Contours {
    /// Below this a sample is a void, not ground. A cell holding one is skipped entirely:
    /// interpolating between ground and nodata invents a cliff.
    static let void = -32000

    let grid: Grid
    /// Metres between lines.
    let step: Int
    /// When false, every crossing is kept, duplicates included, for comparison against
    /// another tracer.
    var tidy = true
    /// How far off the straight line a point may sit and still be dropped, in degrees.
    /// The default is about a millimetre of ground: far below what any device draws.
    static let defaultFlatness = 1e-8
    var flatness = Contours.defaultFlatness
    /// Contour only inside this box. Elevation tiles are whole degrees while a region is
    /// not, so a cell is clipped to the region. pyhgtmap masks the samples instead.
    var clip: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)?

    private func outside(_ row: Int, _ column: Int) -> Bool {
        guard let clip else { return false }
        let lat = grid.latitude(Double(row)), lon = grid.longitude(Double(column))
        return lat < clip.minLat || lat > clip.maxLat || lon < clip.minLon || lon > clip.maxLon
    }

    /// The rows and columns the clip box can reach, with one row and column of slack at each
    /// edge so `outside` remains the deciding test. The whole grid where there is no clip.
    private func clipBounds() -> (rows: Range<Int>, columns: Range<Int>) {
        let whole = 0..<grid.n
        guard let clip else { return (whole, whole) }
        let span = Double(grid.n - 1)
        let top = ((Double(grid.lat) + 1 - clip.maxLat) * span).rounded(.down) - 1
        let bottom = ((Double(grid.lat) + 1 - clip.minLat) * span).rounded(.up) + 1
        let left = ((clip.minLon - Double(grid.lon)) * span).rounded(.down) - 1
        let right = ((clip.maxLon - Double(grid.lon)) * span).rounded(.up) + 1
        func clamp(_ value: Double) -> Int { max(0, min(grid.n - 1, Int(value))) }
        let rows = clamp(top)..<(clamp(bottom) + 1)
        let columns = clamp(left)..<(clamp(right) + 1)
        return (rows.isEmpty ? whole : rows, columns.isEmpty ? whole : columns)
    }

    struct Grid {
        var samples: [Int16]
        var n: Int
        /// South-west corner, whole degrees.
        var lat: Int
        var lon: Int

        func value(_ row: Int, _ column: Int) -> Int {
            Int(samples[row * n + column])
        }

        /// Row 0 is the north edge, as a .hgt stores it.
        func latitude(_ row: Double) -> Double {
            Double(lat) + 1 - row / Double(n - 1)
        }

        func longitude(_ column: Double) -> Double {
            Double(lon) + column / Double(n - 1)
        }

        /// For a caller that already holds the samples.
        init(samples: [Int16], n: Int, lat: Int, lon: Int) {
            self.samples = samples
            self.n = n
            self.lat = lat
            self.lon = lon
        }

        init(contentsOf url: URL) throws {
            let data = try Data(contentsOf: url)
            let count = data.count / 2
            let side = Int(Double(count).squareRoot().rounded())
            guard side * side * 2 == data.count else { throw Trouble.notSquare(url.lastPathComponent) }
            var values = [Int16](repeating: 0, count: count)
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    values[i] = Int16(bitPattern: UInt16(raw[i * 2]) << 8 | UInt16(raw[i * 2 + 1]))
                }
            }
            self.samples = values
            self.n = side
            let corner = HGTName.corner(of: url.lastPathComponent)
            self.lat = corner?.lat ?? 0
            self.lon = corner?.lon ?? 0
        }
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case notSquare(String)
        var description: String {
            if case let .notSquare(name) = self { return "\(name) is not a square .hgt" }
            return ""
        }
    }

    /// The most vertices one way may carry, matching pyhgtmap's limit.
    static let maxPoints = 2000

    /// Splits lines longer than `maxPoints`. Each piece repeats the vertex it shares with
    /// the next, so the line stays joined.
    static func split(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        for line in lines {
            guard line.points.count > maxPoints else {
                out.append(line)
                continue
            }
            var at = 0
            while at < line.points.count - 1 {
                let end = min(at + maxPoints, line.points.count)
                out.append(Line(elevation: line.elevation,
                                points: Array(line.points[at..<end]), closed: false))
                at = end - 1
            }
        }
        return out
    }

    /// One traced line at one elevation.
    struct Line {
        var elevation: Int
        var points: [(lat: Double, lon: Double)]
        var closed: Bool
    }

    /// Every contour in the tile, at every multiple of `step` the ground reaches. One sweep
    /// of the grid serves all levels: a cell's four corners bound which levels can cross it.
    func trace() -> [Line] {
        let bounds = clipBounds()
        var lowest = Int.max, highest = Int.min
        ContourTiming.measure("range") {
        for row in bounds.rows {
            for column in bounds.columns {
                let value = grid.value(row, column)
                guard value > Self.void, !outside(row, column) else { continue }
                lowest = min(lowest, value)
                highest = max(highest, value)
            }
        }
        }
        guard lowest <= highest else { return [] }

        let base = Int((Double(lowest) / Double(step)).rounded(.down)) * step
        var levels: [Int] = []
        var level = base
        while level <= highest {
            levels.append(level)
            level += step
        }
        guard !levels.isEmpty else { return [] }

        var sweep = (0..<levels.count).map { _ in Level(width: grid.n) }
        ContourTiming.measure("collect") {
            collect(into: &sweep, base: base, bounds: bounds)
        }

        var lines: [Line] = []
        ContourTiming.measure("assemble") {
        for (index, level) in levels.enumerated() {
            lines.append(contentsOf: assemble(&sweep[index], level: level))
        }
        }
        return lines
    }

    /// Where every crossing sits and what joins to what, one set per level.
    ///
    /// Crossings are numbered, not keyed: the edge key is used once, so the second cell
    /// sharing an edge can find what the first made. Everything after that — position,
    /// links, walking segments into lines — is an array index.
    private struct Level {
        /// How far along its edge each crossing sits.
        var along: [Double] = []
        /// The edge each crossing sits on, resolved to a position at the end.
        var edge: [Int32] = []
        /// What joins to what. Exactly two slots: a crossing sits on one edge, an edge is
        /// shared by at most two cells, and a cell joins each of its crossings once. -1 is
        /// an unfilled slot, that is, a loose end.
        var linkA: [Int32] = []
        var linkB: [Int32] = []
        /// One row's worth of edges, in place of a map from edge key to crossing number:
        /// one slot per column holding the number, and beside it the row that slot belongs
        /// to. Cells sharing an edge are neighbours in the sweep — an east edge is shared by
        /// the rows above and below, a south edge by the columns left and right — and the
        /// stored row makes a stale slot read as empty without clearing.
        var eastID: [Int32]
        var eastRow: [Int32]
        var southID: [Int32]
        var southRow: [Int32]

        init(width: Int) {
            eastID = [Int32](repeating: -1, count: width)
            eastRow = [Int32](repeating: -1, count: width)
            southID = [Int32](repeating: -1, count: width)
            southRow = [Int32](repeating: -1, count: width)
        }

        /// The crossing on an east edge, created if this is the first cell to reach it.
        /// Both cells sharing the edge derive `along` from the same two samples, so the
        /// first to arrive settles it.
        mutating func east(row: Int32, column: Int, key: Int32, at position: Double) -> Int32 {
            if eastRow[column] == row { return eastID[column] }
            let made = make(key, position)
            eastRow[column] = row
            eastID[column] = made
            return made
        }

        mutating func south(row: Int32, column: Int, key: Int32, at position: Double) -> Int32 {
            if southRow[column] == row { return southID[column] }
            let made = make(key, position)
            southRow[column] = row
            southID[column] = made
            return made
        }

        private mutating func make(_ key: Int32, _ position: Double) -> Int32 {
            let made = Int32(along.count)
            along.append(position)
            edge.append(key)
            linkA.append(-1)
            linkB.append(-1)
            return made
        }

        mutating func join(_ first: Int32, _ second: Int32) {
            // Both second slots must still be free: only the two cells sharing a crossing's
            // edge can join it, and each joins it once.
            assert(linkB[Int(first)] < 0 && linkB[Int(second)] < 0,
                   "a crossing joined three ways — an edge is shared by at most two cells")
            if linkA[Int(first)] < 0 { linkA[Int(first)] = second }
            else { linkB[Int(first)] = second }
            if linkA[Int(second)] < 0 { linkA[Int(second)] = first }
            else { linkB[Int(second)] = first }
        }
    }

    /// Marching squares over every cell, filing each crossing under the level it belongs
    /// to. Which levels a cell can hold follows from its lowest and highest corner.
    private func collect(into sweep: inout [Level], base: Int, bounds: (rows: Range<Int>,
                                                                       columns: Range<Int>)) {
        let n = grid.n
        let clipping = clip != nil

        for row in bounds.rows.lowerBound..<min(bounds.rows.upperBound, n - 1) {
            for column in bounds.columns.lowerBound..<min(bounds.columns.upperBound, n - 1) {
                let topLeft = grid.value(row, column)
                let topRight = grid.value(row, column + 1)
                let bottomLeft = grid.value(row + 1, column)
                let bottomRight = grid.value(row + 1, column + 1)
                guard topLeft > Self.void, topRight > Self.void,
                      bottomLeft > Self.void, bottomRight > Self.void else { continue }

                // A level crosses an edge only when one corner is above it and the other is
                // not, so the levels run from the cell's lowest corner to just under its
                // highest.
                let low = min(min(topLeft, topRight), min(bottomLeft, bottomRight))
                let high = max(max(topLeft, topRight), max(bottomLeft, bottomRight))
                guard low < high else { continue }
                let first = max(0, Self.stepsUp(low - base, step))
                let last = min(sweep.count - 1, Self.stepsUp(high - base, step) - 1)
                guard first <= last else { continue }

                if clipping, outside(row, column) || outside(row, column + 1)
                    || outside(row + 1, column) || outside(row + 1, column + 1) { continue }

                for index in first...last {
                    cell(row: row, column: column, n: n, level: base + index * step,
                         corners: (topLeft, topRight, bottomLeft, bottomRight),
                         into: &sweep, at: index)
                }
            }
        }
    }

    /// How many whole steps reach `distance`, rounding up. Written out because Swift's
    /// integer division rounds towards zero and `distance` can be negative.
    private static func stepsUp(_ distance: Int, _ step: Int) -> Int {
        distance >= 0 ? (distance + step - 1) / step : -((-distance) / step)
    }

    /// One cell at one level: where the contour cuts its edges, and what joins to what.
    private func cell(row: Int, column: Int, n: Int, level: Int,
                      corners: (Int, Int, Int, Int), into sweep: inout [Level], at index: Int) {
        let (topLeft, topRight, bottomLeft, bottomRight) = corners

        func cut(_ a: Int, _ b: Int) -> Double? {
            // "Above" is strictly above: elevations are whole metres and levels are
            // multiples of the step, so samples landing exactly on a level are common, and
            // "at or above" would lose every such crossing.
            guard (a > level) != (b > level) else { return nil }
            return Double(level - a) / Double(b - a)
        }


        // Named rather than collected into a list: which edge is which decides how a saddle
        // is joined, and pairing by key order would cross the two arcs.
        var top: Int32?, bottom: Int32?, left: Int32?, right: Int32?
        if let t = cut(topLeft, topRight) {
            top = sweep[index].east(row: Int32(row), column: column,
                                    key: edgeKey(row, column, south: false), at: t)
        }
        if let t = cut(bottomLeft, bottomRight) {
            bottom = sweep[index].east(row: Int32(row + 1), column: column,
                                       key: edgeKey(row + 1, column, south: false), at: t)
        }
        if let t = cut(topLeft, bottomLeft) {
            left = sweep[index].south(row: Int32(row), column: column,
                                      key: edgeKey(row, column, south: true), at: t)
        }
        if let t = cut(topRight, bottomRight) {
            right = sweep[index].south(row: Int32(row), column: column + 1,
                                       key: edgeKey(row, column + 1, south: true), at: t)
        }

        // Two or four, never one or three: round the four corners, the number of edges where
        // "above the level" changes is even.
        let here = [top, bottom, left, right].compactMap { $0 }
        switch here.count {
        case 2:
            sweep[index].join(here[0], here[1])
        case 4:
            // A saddle: the two arcs cut off one pair of opposite corners, chosen by the
            // cell's mean. Above the level the low corners are the pockets; at or below it
            // the high ones are. Matches contourpy. All four edges are crossed here.
            guard let top, let right, let left, let bottom else { break }
            let middle = Double(topLeft + topRight + bottomLeft + bottomRight) / 4
            if (middle > Double(level)) == (topLeft > level) {
                sweep[index].join(top, right); sweep[index].join(left, bottom)
            } else {
                sweep[index].join(top, left); sweep[index].join(right, bottom)
            }
        default:
            break
        }
    }

    /// A crossing is named by the edge it sits on: `(row, column)` of the cell corner the
    /// edge starts at, and whether it runs east or south from there.
    private func edgeKey(_ row: Int, _ column: Int, south: Bool) -> Int32 {
        Int32(((row * grid.n) + column) * 2 + (south ? 1 : 0))
    }

    /// The position of a crossing, from its edge key and how far along that edge it sits.
    private func place(_ key: Int32, _ along: Double) -> (lat: Double, lon: Double) {
        let south = key & 1 == 1
        let cell = Int(key >> 1)
        let row = cell / grid.n, column = cell % grid.n
        return south
            ? (grid.latitude(Double(row) + along), grid.longitude(Double(column)))
            : (grid.latitude(Double(row)), grid.longitude(Double(column) + along))
    }

    /// Walks the segments into lines: open ones first from their loose ends, then whatever
    /// remains, which can only be closed rings.
    private func assemble(_ sweep: inout Level, level: Int) -> [Line] {
        let count = sweep.along.count
        guard count > 0 else { return [] }
        // Moved into locals so the links are uniquely referenced and the walk writes in
        // place. The rolling row is finished with, and dropping it frees it before the walk.
        sweep.eastID = []; sweep.eastRow = []
        sweep.southID = []; sweep.southRow = []
        let along = sweep.along, edge = sweep.edge
        var linkA = sweep.linkA; sweep.linkA = []
        var linkB = sweep.linkB; sweep.linkB = []

        // Ascending by edge key, which fixes which end of an open line becomes its first
        // point and hence the node order in the file. Edge and crossing number are packed
        // into one integer: no two crossings in a level share an edge, so this sorts by edge.
        var order = [UInt64](repeating: 0, count: count)
        for id in 0..<count {
            order[id] = UInt64(UInt32(bitPattern: edge[id])) << 32 | UInt64(UInt32(id))
        }
        order.sort()

        var lines: [Line] = []

        func detach(_ from: Int32, _ what: Int32) {
            if linkA[Int(from)] == what { linkA[Int(from)] = -1 }
            else if linkB[Int(from)] == what { linkB[Int(from)] = -1 }
        }

        func walk(from start: Int32) -> [Int32] {
            var path = [start]
            var current = start
            while true {
                let first = linkA[Int(current)]
                let next = first >= 0 ? first : linkB[Int(current)]
                guard next >= 0 else { break }
                detach(current, next)
                detach(next, current)
                path.append(next)
                current = next
                if next == start { break }
            }
            return path
        }

        func emit(_ path: [Int32]) {
            guard path.count >= 2 else { return }
            // A crossing landing exactly on a grid node belongs to both edges meeting there,
            // so the same position arrives twice in a row.
            var points: [(lat: Double, lon: Double)] = []
            points.reserveCapacity(path.count)
            for id in path {
                let point = place(edge[Int(id)], along[Int(id)])
                if tidy, let last = points.last, last.lat == point.lat, last.lon == point.lon {
                    continue
                }
                points.append(point)
            }
            // A contour running along a grid line crosses every perpendicular edge, putting
            // those crossings on one straight run; the collinear ones are dropped.
            var kept: [(lat: Double, lon: Double)] = []
            kept.reserveCapacity(points.count)
            for point in points {
                // Folds back over the whole run, since a run can be straight throughout. The
                // test is the middle point's distance off the line against `flatness`, not
                // an exact zero cross product, which floating-point crossings never give.
                while tidy, kept.count >= 2 {
                    let a = kept[kept.count - 2], b = kept[kept.count - 1]
                    let cross = (b.lon - a.lon) * (point.lat - a.lat)
                        - (b.lat - a.lat) * (point.lon - a.lon)
                    let span = ((point.lat - a.lat) * (point.lat - a.lat)
                                + (point.lon - a.lon) * (point.lon - a.lon)).squareRoot()
                    if span == 0 || abs(cross) / span > flatness { break }
                    // Collinear is not enough: the middle point must lie between the other
                    // two, or dropping it would cut the tip off a spike that doubles back.
                    let along = (b.lat - a.lat) * (point.lat - a.lat)
                        + (b.lon - a.lon) * (point.lon - a.lon)
                    let reach = (b.lat - a.lat) * (b.lat - a.lat)
                        + (b.lon - a.lon) * (b.lon - a.lon)
                    if along <= 0 || reach > span * span { break }
                    kept.removeLast()
                }
                kept.append(point)
            }
            guard kept.count >= 2 else { return }
            lines.append(Line(elevation: level, points: kept,
                              closed: path.first == path.last))
        }

        // Loose ends first, so an open contour is walked from one of its ends and comes out
        // whole; anything still linked after that can only be a closed ring.
        for packed in order {
            let id = Int32(truncatingIfNeeded: packed)
            let degree = (linkA[Int(id)] >= 0 ? 1 : 0) + (linkB[Int(id)] >= 0 ? 1 : 0)
            if degree == 1 { emit(walk(from: id)) }
        }
        for packed in order {
            let id = Int32(truncatingIfNeeded: packed)
            if linkA[Int(id)] >= 0 || linkB[Int(id)] >= 0 { emit(walk(from: id)) }
        }
        return lines
    }
}
