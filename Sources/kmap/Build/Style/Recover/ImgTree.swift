import Foundation

/// TRE — the tree of subdivisions: which slice of the RGN each one owns, at which
/// zoom, over which ground.
extension ImgElements {
    struct Subdivision {
        let level: Int
        let shift: Int
        let lat: Int32
        let lon: Int32
        let width: Int
        let height: Int
        let hasPoints: Bool
        let hasIndexedPoints: Bool
        let hasLines: Bool
        let hasAreas: Bool
        let rgnStart: Int
        let rgnEnd: Int
        var extAreasOffset = 0, extAreasSize = 0
        var extLinesOffset = 0, extLinesSize = 0
        var extPointsOffset = 0, extPointsSize = 0

        /// A subdivision states its centre and its size; anything it holds is inside that.
        /// The size is doubled here, erring towards reading a subdivision too many.
        func near(_ ground: Ground) -> Bool {
            let halfLat = Int32((height << shift) * 2 + 2)
            let halfLon = Int32((width << shift) * 2 + 2)
            return lat &+ halfLat >= ground.minLat && lat &- halfLat <= ground.maxLat
                && lon &+ halfLon >= ground.minLon && lon &- halfLon <= ground.maxLon
        }
    }

    struct Tree {
        var subdivisions: [Subdivision] = []

        init(_ data: Data, tile: String) throws {
            var r = Bytes(data)
            guard data.count >= 0x31 else { throw Trouble.malformed(tile, "TRE too short") }
            let headerLength = Int(r.u16(at: 0))
            let locked = r.u8(at: 0x0D) & 0x80 != 0
            let levelsPos = Int(r.u32(at: 0x21)), levelsSize = Int(r.u32(at: 0x25))
            let subdivPos = Int(r.u32(at: 0x29)), subdivSize = Int(r.u32(at: 0x2D))
            guard levelsPos + levelsSize <= data.count, subdivPos + subdivSize <= data.count
            else { throw Trouble.malformed(tile, "TRE sections past the end") }

            let ladder = Self.mapLevels(data, at: levelsPos, size: levelsSize,
                                        locked: locked, headerLength: headerLength,
                                        reader: r)
            readSubdivisions(&r, ladder: ladder, from: subdivPos, size: subdivSize)
            readExtendedOffsets(&r, ladder: ladder, headerLength: headerLength,
                                count: data.count)
        }

        /// The map levels: level, resolution, and how many subdivisions each holds. A
        /// locked map's table is unscrambled first.
        private static func mapLevels(_ data: Data, at levelsPos: Int, size levelsSize: Int,
                                      locked: Bool, headerLength: Int, reader r: Bytes)
            -> [(level: Int, resolution: Int, count: Int)] {
            var levels = Array(data[levelsPos..<(levelsPos + levelsSize)])
            if locked, headerLength >= 0xAA, data.count >= 0xAE {
                Self.demangle(&levels, key: r.u32(at: 0xAA))
            }
            var ladder: [(level: Int, resolution: Int, count: Int)] = []
            var used = 0
            while used + 4 <= levels.count {
                let level = Int(levels[used] & 0x7f)
                let resolution = Int(levels[used + 1])
                let count = Int(levels[used + 2]) | Int(levels[used + 3]) << 8
                ladder.append((level, resolution, count))
                used += 4
            }
            return ladder
        }

        /// The subdivisions, level by level: each record ends with the RGN offset the
        /// NEXT one starts at, and the first offset stands alone in front.
        private mutating func readSubdivisions(
            _ r: inout Bytes, ladder: [(level: Int, resolution: Int, count: Int)],
            from subdivPos: Int, size subdivSize: Int) {
            r.position = subdivPos
            let end = subdivPos + subdivSize
            var lastRgnOffset = Int(r.u24())
            for (index, rung) in ladder.enumerated() {
                for _ in 0..<rung.count {
                    guard r.position < end else { break }
                    let flags = r.u8()
                    let lon = r.s24()
                    let lat = r.s24()
                    let width = Int(r.u16()) & 0x7fff
                    let height = Int(r.u16())
                    if index < ladder.count - 1 { _ = r.u16() }
                    let endRgnOffset = Int(r.u24())
                    subdivisions.append(Subdivision(
                        level: rung.level, shift: 24 - rung.resolution,
                        lat: lat, lon: lon, width: width, height: height,
                        hasPoints: flags & 0x10 != 0, hasIndexedPoints: flags & 0x20 != 0,
                        hasLines: flags & 0x40 != 0, hasAreas: flags & 0x80 != 0,
                        rgnStart: lastRgnOffset, rgnEnd: endRgnOffset))
                    lastRgnOffset = endRgnOffset
                }
            }
        }

        /// TRE7: where each subdivision's extended-type elements sit in the RGN. A map
        /// without the section, or with one that will not read, leaves the offsets at
        /// zero, which downstream reads as "no extended elements".
        private mutating func readExtendedOffsets(
            _ r: inout Bytes, ladder: [(level: Int, resolution: Int, count: Int)],
            headerLength: Int, count: Int) {
            guard headerLength > 120, count >= 0x8A else { return }
            let extPos = Int(r.u32(at: 0x7C)), extSize = Int(r.u32(at: 0x80))
            let recordSize = Int(r.u16(at: 0x84))
            let magic = Int(r.u32(at: 0x86))
            guard magic & 7 != 0, recordSize > 0, extSize % recordSize == 0,
                  extPos + extSize <= count else { return }
            // With a record size past 13 there may be no data for the first level(s):
            // count records back from the finest level to see where they begin.
            var available = extSize / recordSize
            var firstLevel = 0
            for index in stride(from: ladder.count - 1, through: 0, by: -1) {
                available -= ladder[index].count
                guard available >= 0 else { return }
                if available == 1 { firstLevel = index; break }
            }
            r.position = extPos
            let extEnd = extPos + extSize
            var previous: Int?
            var at = 0
            for (index, rung) in ladder.enumerated() {
                if index < firstLevel { at += rung.count; continue }
                for _ in 0..<rung.count {
                    guard r.position < extEnd else { break }
                    let next = r.position + recordSize
                    if magic & 1 != 0 { subdivisions[at].extAreasOffset = Int(r.u32()) }
                    if magic & 2 != 0 { subdivisions[at].extLinesOffset = Int(r.u32()) }
                    if magic & 4 != 0 { subdivisions[at].extPointsOffset = Int(r.u32()) }
                    r.position = next
                    if let previous {
                        subdivisions[previous].extAreasSize =
                            subdivisions[at].extAreasOffset - subdivisions[previous].extAreasOffset
                        subdivisions[previous].extLinesSize =
                            subdivisions[at].extLinesOffset - subdivisions[previous].extLinesOffset
                        subdivisions[previous].extPointsSize =
                            subdivisions[at].extPointsOffset - subdivisions[previous].extPointsOffset
                    }
                    previous = at
                    at += 1
                }
            }
            if let previous, r.position < extEnd {
                if magic & 1 != 0 {
                    subdivisions[previous].extAreasSize = Int(r.u32()) - subdivisions[previous].extAreasOffset
                }
                if magic & 2 != 0 {
                    subdivisions[previous].extLinesSize = Int(r.u32()) - subdivisions[previous].extLinesOffset
                }
                if magic & 4 != 0 {
                    subdivisions[previous].extPointsSize = Int(r.u32()) - subdivisions[previous].extPointsOffset
                }
            }
        }

        /// A locked map's level table is scrambled with a key from its header. The
        /// unscrambling is mkgmap's, which took it from gimgtools.
        private static func demangle(_ data: inout [UInt8], key: UInt32) {
            let shuffle: [Int] = [0xb, 0xc, 0xa, 0x0, 0x8, 0xf, 0x2, 0x1,
                                  0x6, 0x4, 0x9, 0x3, 0xd, 0x5, 0x7, 0xe]
            let key = Int32(bitPattern: key)
            // Written out in steps, with the type stated. As one expression the Linux
            // compiler gives up on it -- "unable to type-check this expression in
            // reasonable time" -- because every literal shift and mask is an overload it
            // has to consider against Int32 and Int at once. Naming the type settles it,
            // and the arithmetic is unchanged.
            let folded: Int32 = (key >> 24) &+ (key >> 16) &+ (key >> 8) &+ key
            let sum: Int = shuffle[Int(folded & 0xf)]
            var ring = 16
            for i in data.indices {
                var upper = Int(Int8(bitPattern: data[i])) >> 4
                var lower = Int(Int8(bitPattern: data[i]))
                upper -= sum
                upper -= Int(key >> Int32(ring))
                upper -= shuffle[Int((key >> Int32(ring)) & 0xf)]
                ring = ring != 0 ? ring - 4 : 16
                lower -= sum
                lower -= Int(key >> Int32(ring))
                lower -= shuffle[Int((key >> Int32(ring)) & 0xf)]
                ring = ring != 0 ? ring - 4 : 16
                data[i] = UInt8(truncatingIfNeeded: ((upper << 4) & 0xf0) | (lower & 0xf))
            }
        }
    }
}
