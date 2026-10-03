import CVector
import Foundation

/// Turns GeoTIFF elevation tiles into the `.hgt` grid the rest of the pipeline reads.
///
/// Sampling reads from every tile at once. A `.hgt` covers a whole degree *inclusive*: its
/// eastmost column belongs to the next cell east and its southmost row to the cell below,
/// so reading tile by tile would leave those edges with nothing to sample.
enum HGTConversion {
    /// A degree in arc seconds, and the lattice's unit: a thousandth of one.
    static let arcSecondsPerDegree = 3600
    static let latticePerArcSecond = 1000
    private static let latticePerDegree = arcSecondsPerDegree * latticePerArcSecond

    /// Writes heights as big-endian Int16, held to the type's range and rounded half away
    /// from zero. A height that is not finite, or is `nodata`, is written as 0 and not
    /// counted. Returns how many were stored.
    static func storeHeights(
        _ heights: UnsafePointer<Float>,
        count: Int,
        nodata: Float?,
        into out: UnsafeMutablePointer<UInt8>
    ) -> Int {
        let stored = kmap_heights_f32(heights, count, nodata ?? 0, nodata == nil ? 0 : 1, out)
        if stored >= 0 { return Int(stored) }
        return plainStoreHeights(count: count, into: out) { i in
            let height = heights[i]
            return height == nodata ? nil : Double(height)
        }
    }

    static func storeHeights(
        _ heights: UnsafePointer<Double>,
        count: Int,
        into out: UnsafeMutablePointer<UInt8>
    ) -> Int {
        let stored = kmap_heights_f64(heights, count, out)
        if stored >= 0 { return Int(stored) }
        return plainStoreHeights(count: count, into: out) { heights[$0] }
    }

    /// The same a height at a time: no vector code, and the tests. A nil height is a hole.
    static func plainStoreHeights(
        count: Int,
        into out: UnsafeMutablePointer<UInt8>,
        height: (Int) -> Double?
    ) -> Int {
        var stored = 0
        for i in 0..<count {
            var metres: Int16 = 0
            if let h = height(i), h.isFinite {
                metres = Int16(min(max(h, Double(Int16.min)), Double(Int16.max)).rounded(.toNearestOrAwayFromZero))
                stored += 1
            }
            out[i * 2] = UInt8(truncatingIfNeeded: metres >> 8)
            out[i * 2 + 1] = UInt8(truncatingIfNeeded: metres)
        }
        return stored
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case noData(String)

        var description: String {
            switch self {
            case .noData(let cell): "no elevation data covering \(cell)"
            }
        }
    }

    /// The tiles available to sample from, opened as they are wanted and then kept.
    /// Asked from every lane of a conversion. `@unchecked Sendable` stands on `lock`: the
    /// open tiles and the absent set are reached only under it.
    final class Mosaic: @unchecked Sendable {
        private var open: [Int: GeoTIFF] = [:]
        private var absent: Set<Int> = []
        private let locate: (Int, Int) -> URL?
        private let lock = NSLock()

        /// - Parameter locate: the file holding the degree cell, if there is one. A cell
        ///   that is entirely sea has no file, which is not an error.
        init(locate: @escaping (Int, Int) -> URL?) {
            self.locate = locate
        }

        /// The nine cells a node of this one can be answered from: its own, and the
        /// neighbours the southern row, the eastern column and the corner belong to.
        private static let neighbourhood = [
            (0, 0), (-1, 0), (0, 1), (-1, 1),
            (0, -1), (-1, -1), (1, 0), (1, 1), (1, -1)
        ]

        /// Whether anything at all covers this cell or the neighbours it borrows from.
        /// Asked once before the grid is filled, so a cell nothing covers is refused before
        /// 12 967 201 nodes are each tried against nine neighbours under the lock.
        func covers(cellLat: Int, cellLon: Int) -> Bool {
            Self.neighbourhood.contains { tile(lat: cellLat + $0.0, lon: cellLon + $0.1) != nil }
        }

        /// Lets the cell's own file forget its decoded tiles. A neighbour still to come
        /// decodes the edge it borrows again, which is far cheaper than keeping every
        /// cell of a large region decoded until the pass ends.
        func release(cellLat: Int, cellLon: Int) {
            lock.lock()
            let tiff = open[cellLat * 1000 + cellLon]
            lock.unlock()
            tiff?.dropDecoded()
        }

        func tile(lat: Int, lon: Int) -> GeoTIFF? {
            // Keyed by number rather than by name: this is asked once per node in the slow
            // path, and building the name was a String(format:) each time.
            let key = lat * 1000 + lon
            lock.lock()
            defer { lock.unlock() }
            if let hit = open[key] { return hit }
            if absent.contains(key) { return nil }
            guard let url = locate(lat, lon), let tiff = try? GeoTIFF(contentsOf: url) else {
                absent.insert(key)
                return nil
            }
            open[key] = tiff
            return tiff
        }

        /// The height at one node of the output grid, bilinear between the samples around it.
        ///
        /// The node is named by whole numbers - which degree cell, and which of its 3601 rows
        /// and columns - never by latitude and longitude. Sources publish on whole
        /// arc-seconds, which integers name exactly and degrees round.
        func height(cellLat: Int, cellLon: Int, row: Int, column: Int) -> Double? {
            // The node's own cell first, then every neighbour: the southern row belongs to
            // the cell below, the eastern column to the right, the corner to the diagonal.
            for (dLat, dLon) in Self.neighbourhood {
                guard let tiff = tile(lat: cellLat + dLat, lon: cellLon + dLon) else { continue }
                if let value = sample(
                    tiff,
                    cellLat: cellLat,
                    cellLon: cellLon,
                    row: row,
                    column: column
                ) {
                    return value
                }
            }
            return nil
        }

        /// Where each node of an output row falls on a source row: the sample to its
        /// west, and how far past it the node is, in the lattice's unit. The same for
        /// every row of a tile, so it is worked out for the first and kept.
        struct RowPlan {
            fileprivate let originLon: Int, stepLon: Int, cellLon: Int, step: Int
            /// -1 where the node lies west of the tile.
            fileprivate var west: [Int]
            fileprivate var past: [Double]

            fileprivate init(originLon: Int, stepLon: Int, cellLon: Int, step: Int, width n: Int) {
                self.originLon = originLon
                self.stepLon = stepLon
                self.cellLon = cellLon
                self.step = step
                west = [Int](repeating: -1, count: n)
                past = [Double](repeating: 0, count: n)
                for column in 0..<n {
                    let east =
                        (cellLon * HGTConversion.arcSecondsPerDegree + column * step)
                        * HGTConversion.latticePerArcSecond - originLon
                    guard east >= 0 else { continue }
                    let x0 = Mosaic.floorDiv(east, stepLon)
                    west[column] = x0
                    past[column] = Double(east - x0 * stepLon)
                }
            }

            fileprivate func serves(originLon: Int, stepLon: Int, cellLon: Int, step: Int, width n: Int) -> Bool {
                self.originLon == originLon && self.stepLon == stepLon && self.cellLon == cellLon
                    && self.step == step && west.count == n
            }
        }

        /// A whole output row at once into `out`, which has room for `n` heights, or
        /// false if no single tile carries it. A node with nothing under it is NaN.
        ///
        /// Latitude is sampled once an arc-second everywhere, so the source row is read once
        /// and interpolated along. `step` is the output grid's spacing in arc-seconds - 1 for
        /// a 3601-node cell, 3 for a 1201-node one; a source of another step is refused.
        func row(
            cellLat: Int,
            cellLon: Int,
            row: Int,
            width n: Int,
            step: Int = 1,
            plan: inout RowPlan?,
            into out: UnsafeMutablePointer<Double>
        ) -> Bool {
            let lat =
                ((cellLat + 1) * HGTConversion.arcSecondsPerDegree - row * step)
                * HGTConversion.latticePerArcSecond
            // The row belongs to this cell unless it is the southern edge, which is the
            // first row of the cell below.
            let owner = row < n - 1 ? cellLat : cellLat - 1
            guard let tiff = tile(lat: owner, lon: cellLon), let grid = lattice(of: tiff),
                grid.stepLat == step * 1000
            else { return false }
            let south = grid.originLat - lat
            guard south >= 0, south % grid.stepLat == 0 else { return false }
            let y = south / grid.stepLat
            guard y >= 0, y < tiff.height, let source = try? tiff.row(y) else { return false }

            // The tile to the east, for nodes past this one's last sample.
            var beyond: [Float] = []
            let neighbour = tile(
                lat: owner,
                lon: Self.floorDiv(grid.originLon, HGTConversion.latticePerDegree) + 1
            )
            if let neighbour, let far = lattice(of: neighbour), far.stepLon == grid.stepLon,
                far.stepLat == grid.stepLat
            {
                let theirSouth = far.originLat - lat
                if theirSouth >= 0, theirSouth % far.stepLat == 0 {
                    let theirRow = theirSouth / far.stepLat
                    if theirRow >= 0, theirRow < neighbour.height {
                        beyond = (try? neighbour.row(theirRow)) ?? []
                    }
                }
            }

            if plan?.serves(originLon: grid.originLon, stepLon: grid.stepLon, cellLon: cellLon, step: step, width: n)
                != true
            {
                plan = RowPlan(
                    originLon: grid.originLon,
                    stepLon: grid.stepLon,
                    cellLon: cellLon,
                    step: step,
                    width: n
                )
            }
            guard let plan else { return false }
            let stepLon = Double(grid.stepLon)
            source.withUnsafeBufferPointer { near in
                beyond.withUnsafeBufferPointer { far in
                    plan.west.withUnsafeBufferPointer { west in
                        plan.past.withUnsafeBufferPointer { past in
                            let nearCount = near.count, total = near.count + far.count
                            @inline(__always)
                            func at(_ x: Int) -> Double {
                                if x < nearCount { return Double(near[x]) }
                                return x < total ? Double(far[x - nearCount]) : .nan
                            }
                            for column in 0..<n {
                                let x = west[column]
                                guard x >= 0 else {
                                    out[column] = .nan
                                    continue
                                }
                                let left = at(x)
                                let over = past[column]
                                out[column] = over == 0 ? left : left + (at(x + 1) - left) * over / stepLon
                            }
                        }
                    }
                }
            }
            return true
        }

        /// Where a node sits inside one tile, and the height there.
        ///
        /// Positions count in thousandths of an arc-second from the equator and the prime
        /// meridian. Past 50 deg of latitude Copernicus thins longitude sampling to 2400 samples
        /// a degree, a step of one and a half seconds that whole arc-seconds cannot name.
        private func sample(
            _ tiff: GeoTIFF,
            cellLat: Int,
            cellLon: Int,
            row: Int,
            column: Int
        ) -> Double? {
            guard let grid = lattice(of: tiff) else { return nil }
            let lon =
                (cellLon * HGTConversion.arcSecondsPerDegree + column)
                * HGTConversion.latticePerArcSecond
            let lat =
                ((cellLat + 1) * HGTConversion.arcSecondsPerDegree - row)
                * HGTConversion.latticePerArcSecond

            let east = lon - grid.originLon
            let south = grid.originLat - lat
            guard east >= 0, south >= 0 else { return nil }
            let x0 = Self.floorDiv(east, grid.stepLon)
            let y0 = Self.floorDiv(south, grid.stepLat)
            let fx = Double(east - x0 * grid.stepLon) / Double(grid.stepLon)
            let fy = Double(south - y0 * grid.stepLat) / Double(grid.stepLat)
            guard x0 >= 0, y0 >= 0, x0 < tiff.width, y0 < tiff.height else { return nil }

            // Straight onto a sample, which is where most nodes land.
            if fx == 0, fy == 0 {
                return (try? tiff.value(row: y0, column: x0)).flatMap { $0.map(Double.init) }
            }

            // The right-hand samples may be the next tile's first column: a thinned tile's
            // last node sits halfway to the next degree. East and west share one lattice.
            func value(_ x: Int, _ y: Int) -> Double? {
                guard y >= 0, y < tiff.height else { return nil }
                if x < tiff.width {
                    return (try? tiff.value(row: y, column: x)).flatMap { $0.map(Double.init) }
                }
                // The neighbour east of *this tile*, which on the southernmost row is not
                // the neighbour east of the cell being written: that row comes from below.
                let here = (
                    lat: Self.floorDiv(grid.originLat, HGTConversion.latticePerDegree) - 1,
                    lon: Self.floorDiv(grid.originLon, HGTConversion.latticePerDegree)
                )
                guard let next = tile(lat: here.lat, lon: here.lon + 1),
                    let far = lattice(of: next), far.stepLon == grid.stepLon
                else { return nil }
                let over = x - tiff.width
                guard over < next.width else { return nil }
                return (try? next.value(row: y, column: over)).flatMap { $0.map(Double.init) }
            }

            guard let topLeft = value(x0, y0) else { return nil }
            if fx == 0 {
                guard let bottomLeft = value(x0, y0 + 1) else { return topLeft }
                return topLeft + (bottomLeft - topLeft) * fy
            }
            guard let topRight = value(x0 + 1, y0) else { return nil }
            let top = topLeft + (topRight - topLeft) * fx
            if fy == 0 { return top }
            guard let bottomLeft = value(x0, y0 + 1),
                let bottomRight = value(x0 + 1, y0 + 1)
            else { return top }
            let bottom = bottomLeft + (bottomRight - bottomLeft) * fx
            return top + (bottom - top) * fy
        }

        /// The tile's grid in thousandths of an arc-second, if it is aligned to whole degrees
        /// on a step that divides one. Anything else is refused rather than guessed at.
        private func lattice(
            of tiff: GeoTIFF
        ) -> (originLon: Int, originLat: Int, stepLon: Int, stepLat: Int)? {
            let unit = Double(HGTConversion.latticePerDegree)
            let stepLon = (tiff.stepLon * unit).rounded()
            let stepLat = (-tiff.stepLat * unit).rounded()
            let originLon = (tiff.originLon * unit).rounded()
            let originLat = (tiff.originLat * unit).rounded()
            guard abs(tiff.stepLon * unit - stepLon) < 1e-3, stepLon >= 1,
                abs(-tiff.stepLat * unit - stepLat) < 1e-3, stepLat >= 1,
                abs(tiff.originLon * unit - originLon) < 1e-3,
                abs(tiff.originLat * unit - originLat) < 1e-3
            else { return nil }
            return (Int(originLon), Int(originLat), Int(stepLon), Int(stepLat))
        }

        fileprivate static func floorDiv(_ a: Int, _ b: Int) -> Int {
            let q = a / b
            return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
        }
    }

    /// Writes one degree cell as `.hgt`: 3601 x 3601 big-endian 16-bit, northmost row first.
    ///
    /// Heights are rounded to the nearest metre, halves away from zero: 0.5 becomes 1 and
    /// -3.5 becomes -4, matching `gdal_translate -ot Int16` with no warping in the way.
    @discardableResult
    static func write(
        cell: (lat: Int, lon: Int),
        from mosaic: Mosaic,
        to url: URL,
        nodes: Int = HGTConversion.arcSecondsPerDegree + 1
    ) throws -> Int {
        let n = nodes
        // 3601 nodes step one arc-second, 1201 step three. The mosaic works in arc-seconds;
        // this scales output indices into that unit, so step 1 is unchanged.
        precondition((arcSecondsPerDegree % (n - 1)) == 0, "a .hgt side must divide the degree")
        let step = arcSecondsPerDegree / (n - 1)
        guard mosaic.covers(cellLat: cell.lat, cellLon: cell.lon) else {
            throw Trouble.noData(CopernicusDEM.cellName(lat: cell.lat, lon: cell.lon))
        }
        var out = [UInt8](repeating: 0, count: n * n * 2)
        var written = 0

        /// The 2 bytes of a height, or nil for one that is not a number: a float DEM
        /// may carry NaN as its nodata, and Int(NaN) traps.
        @inline(__always)
        func metres(_ height: Double) -> Int16? {
            guard height.isFinite else { return nil }
            let bounded = min(max(height, Double(Int16.min)), Double(Int16.max))
            return Int16(clamping: Int(bounded.rounded(.toNearestOrAwayFromZero)))
        }

        func put(_ height: Double, _ row: Int, _ column: Int) {
            guard let metres = metres(height) else { return }
            let at = (row * n + column) * 2
            out[at] = UInt8(truncatingIfNeeded: Int(metres) >> 8)
            out[at + 1] = UInt8(truncatingIfNeeded: Int(metres))
            written += 1
        }

        // Every published source samples latitude once an arc-second, so a whole output row
        // is lifted at once; longitude thins past 50 deg, so the row is interpolated across.
        var line = [Double](repeating: .nan, count: n)
        var plan: Mosaic.RowPlan?
        for row in 0..<n {
            let lifted = line.withUnsafeMutableBufferPointer { heights -> Bool in
                guard let base = heights.baseAddress else { return false }
                return mosaic.row(
                    cellLat: cell.lat,
                    cellLon: cell.lon,
                    row: row,
                    width: n,
                    step: step,
                    plan: &plan,
                    into: base
                )
            }
            if lifted {
                // A hole stores 0, which the fresh row already holds.
                written += out.withUnsafeMutableBufferPointer { bytes -> Int in
                    line.withUnsafeBufferPointer { heights -> Int in
                        Self.storeHeights(heights.baseAddress!, count: n, into: bytes.baseAddress! + row * n * 2)
                    }
                }
                continue
            }
            for column in 0..<n {
                guard
                    let height = mosaic.height(
                        cellLat: cell.lat,
                        cellLon: cell.lon,
                        row: row * step,
                        column: column * step
                    )
                else { continue }
                put(height, row, column)
            }
        }
        guard written > 0 else {
            throw Trouble.noData(
                CopernicusDEM.cellName(
                    lat: cell.lat,
                    lon: cell.lon
                )
            )
        }
        try FileTools.write(Data(out), to: url)
        return written
    }
}
