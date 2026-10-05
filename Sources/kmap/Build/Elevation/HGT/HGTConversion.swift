import CVector
import Foundation

/// Turns GeoTIFF elevation tiles into the `.hgt` grid the rest of the pipeline reads.
///
/// Sampling reads from every tile at once. A `.hgt` covers a whole degree inclusive: its
/// eastmost column belongs to the next cell east and its southmost row to the cell below,
/// so reading tile by tile would leave those edges with nothing to sample.
enum HGTConversion {
    /// A degree in arc seconds, and the lattice's unit: a thousandth of 1.
    static let arcSecondsPerDegree = 3600
    static let latticePerArcSecond = 1000
    static let latticePerDegree = arcSecondsPerDegree * latticePerArcSecond

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case noData(String)

        var description: String {
            switch self {
            case .noData(let cell): "no elevation data covering \(cell)"
            }
        }
    }

    /// Writes 1 degree cell as `.hgt`: `nodes` x `nodes` big-endian 16-bit, northmost row
    /// first. Returns the nodes that hold a height; none is an error.
    ///
    /// Heights are rounded to the nearest metre, halves away from 0: 0.5 becomes 1 and
    /// -3.5 becomes -4, matching `gdal_translate -ot Int16` with no warping in the way.
    @discardableResult
    static func write(
        cell: (lat: Int, lon: Int),
        from mosaic: Mosaic,
        to url: URL,
        nodes n: Int = HGTConversion.arcSecondsPerDegree + 1
    ) throws -> Int {
        // 3601 nodes step 1 arc-second, 1201 step 3.
        precondition((arcSecondsPerDegree % (n - 1)) == 0, "a .hgt side must divide the degree")
        let step = arcSecondsPerDegree / (n - 1)
        let name = HGTName.of(lat: cell.lat, lon: cell.lon)
        // A cell whose own file is there and does not read is not sea: written from its
        // neighbours' edges alone it would be flat, and kept.
        _ = mosaic.tile(lat: cell.lat, lon: cell.lon)
        if let failure = mosaic.failure(lat: cell.lat, lon: cell.lon) { throw failure }
        guard mosaic.covers(cellLat: cell.lat, cellLon: cell.lon) else { throw Trouble.noData(name) }
        // A hole stores 0, which the fresh grid already holds.
        var out = [UInt8](repeating: 0, count: n * n * 2)
        var written = 0

        // Every published source samples latitude once an arc-second, so a whole output row
        // is lifted at once; longitude thins past 50 deg, so the row is interpolated across.
        var line = [Double](repeating: .nan, count: n)
        var plan: Mosaic.RowPlan?
        for row in 0..<n {
            let lifted = line.withUnsafeMutableBufferPointer { heights in
                mosaic.row(
                    cellLat: cell.lat,
                    cellLon: cell.lon,
                    row: row,
                    width: n,
                    step: step,
                    plan: &plan,
                    into: heights.baseAddress!
                )
            }
            if lifted {
                written += out.withUnsafeMutableBufferPointer { bytes in
                    line.withUnsafeBufferPointer { heights in
                        storeHeights(heights.baseAddress!, count: n, into: bytes.baseAddress! + row * n * 2)
                    }
                }
                continue
            }
            // No single tile carries the row: a node at a time.
            for column in 0..<n {
                guard
                    let height = mosaic.height(
                        cellLat: cell.lat,
                        cellLon: cell.lon,
                        row: row * step,
                        column: column * step
                    ), let metres = metres(height)
                else { continue }
                let at = (row * n + column) * 2
                out[at] = UInt8(truncatingIfNeeded: metres >> 8)
                out[at + 1] = UInt8(truncatingIfNeeded: metres)
                written += 1
            }
        }
        guard written > 0 else { throw Trouble.noData(name) }
        try FileTools.write(Data(out), to: url)
        return written
    }

    // MARK: Heights as stored

    /// A height as `.hgt` stores it: whole metres, held to the type's range and rounded
    /// half away from 0. Nil for one that is not finite: a float DEM may carry NaN.
    @inline(__always)
    static func metres(_ height: Double) -> Int16? {
        guard height.isFinite else { return nil }
        return Int16(min(max(height, Double(Int16.min)), Double(Int16.max)).rounded(.toNearestOrAwayFromZero))
    }

    /// Writes heights as big-endian Int16. A height that is not finite, or is `nodata`,
    /// is written as 0 and not counted. Returns how many were stored.
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
            var value: Int16 = 0
            if let known = height(i).flatMap(metres) {
                value = known
                stored += 1
            }
            out[i * 2] = UInt8(truncatingIfNeeded: value >> 8)
            out[i * 2 + 1] = UInt8(truncatingIfNeeded: value)
        }
        return stored
    }
}
