import Foundation

@testable import kmap

/// A TRE of 2 levels, as much of one as the readers of subdivisions need: the header with
/// its bounds, a coarse subdivision over everything, and the detail ones handed in. And
/// the RGN holding their points.
enum TreFixture {
    static func units(_ degrees: Double) -> Int { Int((degrees * Double(1 << 24) / 360).rounded()) }

    private static func put(_ value: Int, bytes: Int, into out: inout [UInt8]) {
        for at in 0..<bytes { out.append(UInt8(truncatingIfNeeded: value >> (8 * at))) }
    }

    /// - Parameter bounds: the tile's box, its east edge past 180 where it crosses.
    static func tre(bounds: BBox, detail: [Detail]) -> [UInt8] {
        let headerLength = 0x31
        var levels: [UInt8] = [1, 22, 1, 0, 0, 24]
        put(detail.count, bytes: 2, into: &levels)
        var divisions: [UInt8] = []
        put(0, bytes: 3, into: &divisions)
        // Coarse: over the whole tile, no data of its own.
        divisions.append(0x40)
        put(units((bounds.minLon + bounds.maxLon) / 2), bytes: 3, into: &divisions)
        put(units((bounds.minLat + bounds.maxLat) / 2), bytes: 3, into: &divisions)
        put(units((bounds.maxLon - bounds.minLon) / 2) >> 2, bytes: 2, into: &divisions)
        put(units((bounds.maxLat - bounds.minLat) / 2) >> 2, bytes: 2, into: &divisions)
        put(0, bytes: 2, into: &divisions)
        put(0, bytes: 3, into: &divisions)
        var end = 0
        for one in detail {
            end += one.rgnBytes
            // Points where it has them, else lines nobody reads.
            divisions.append(one.points.isEmpty ? 0x40 : 0x10)
            // A longitude past 180 deg is written as it wraps.
            put(units(one.lon > 180 ? one.lon - 360 : one.lon), bytes: 3, into: &divisions)
            put(units(one.lat), bytes: 3, into: &divisions)
            put(units(one.halfLon), bytes: 2, into: &divisions)
            put(units(one.halfLat), bytes: 2, into: &divisions)
            put(end, bytes: 3, into: &divisions)
        }
        var tre = [UInt8](repeating: 0, count: headerLength)
        tre[0] = UInt8(headerLength)
        tre.replaceSubrange(2..<12, with: Array("GARMIN TRE".utf8))
        var corners: [UInt8] = []
        for edge in [bounds.maxLat, bounds.maxLon, bounds.minLat, bounds.minLon] {
            put(units(edge > 180 ? edge - 360 : edge), bytes: 3, into: &corners)
        }
        tre.replaceSubrange(0x15..<0x21, with: corners)
        var places: [UInt8] = []
        for value in [headerLength, levels.count, headerLength + levels.count, divisions.count] {
            put(value, bytes: 4, into: &places)
        }
        tre.replaceSubrange(0x21..<0x31, with: places)
        return tre + levels + divisions
    }

    /// The RGN of the same subdivisions: a header, then every point as its record.
    static func rgn(detail: [Detail]) -> [UInt8] {
        let headerLength = 0x1D
        var rgn = [UInt8](repeating: 0, count: headerLength)
        rgn[0] = UInt8(headerLength)
        rgn[0x15] = UInt8(headerLength)
        for point in detail.flatMap(\.points) {
            rgn.append(UInt8(point.type))
            put(point.sub == nil ? 0 : 0x800000, bytes: 3, into: &rgn)
            put(point.dLon, bytes: 2, into: &rgn)
            put(point.dLat, bytes: 2, into: &rgn)
            if let sub = point.sub { rgn.append(UInt8(sub)) }
        }
        return rgn
    }
}
