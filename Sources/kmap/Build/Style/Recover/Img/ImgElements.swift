import Foundation

/// Reads a compiled map's elements from the TRE/RGN pairs inside a Garmin `.img`.
///
/// Every tile, the most detailed level of each, and in it the polylines, polygons and
/// points - classic and extended types alike - in the file's own 24-bit map units.
enum ImgElements {
    struct Coord {
        let lat: Int32
        let lon: Int32
    }

    /// A rectangle of map units the caller is interested in. Elements entirely outside
    /// every ground are skipped, and subdivisions nowhere near one are not even read.
    struct Ground {
        let minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32

        /// From degrees, with one map unit of slack either side, so a vertex sitting
        /// exactly on the edge is kept.
        init(_ box: BBox) {
            let units = Double(1 << 24) / 360.0
            minLat = Int32((box.minLat * units).rounded(.down)) - 1
            minLon = Int32((box.minLon * units).rounded(.down)) - 1
            maxLat = Int32((box.maxLat * units).rounded(.up)) + 1
            maxLon = Int32((box.maxLon * units).rounded(.up)) + 1
        }

        func contains(_ c: Coord) -> Bool {
            c.lat >= minLat && c.lat <= maxLat && c.lon >= minLon && c.lon <= maxLon
        }
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case noTiles
        case malformed(String, String)
        var description: String {
            switch self {
            case .noTiles: return "no map tiles found — is this a Garmin .img?"
            case .malformed(let tile, let what): return "\(tile): \(what)"
            }
        }
    }

    /// Walks the map and hands every element of the detail level to `emit`, in the
    /// order the file has them: tile by tile, subdivision by subdivision, lines then
    /// polygons then points within each.
    ///
    /// - Parameters:
    ///   - extendedAreasAndPoints: whether polygons and points of the extended types
    ///     (0x10000 and up) are read. Lines of extended types are always read.
    ///   - tick: called once per element read, for progress.
    /// - Parameter resolution: read only the subdivisions drawn at this resolution,
    ///   whatever level or tile they live in - the way to compare two maps that ladder
    ///   their zooms differently, or to ask what one draws at a given zoom.
    static func read(
        img: URL,
        grounds: [Ground],
        extendedAreasAndPoints: Bool,
        coarserLevels: Bool = false,
        resolution: Int? = nil,
        tick: () throws -> Void,
        emit: (ElementDumper.Kind, Int, [Coord]) -> Void
    ) throws {
        try read(
            img: img,
            grounds: grounds,
            extendedAreasAndPoints: extendedAreasAndPoints,
            coarserLevels: coarserLevels,
            resolution: resolution,
            tick: tick
        ) {
            kind,
            type,
            coords,
            _ in emit(kind, type, coords)
        }
    }

    /// The same walk, telling the caller which resolution each element is drawn at: a
    /// style may keep a second, thinner vocabulary for the zoomed-out levels, and only
    /// the resolution tells the two apart.
    static func read(
        img: URL,
        grounds: [Ground],
        extendedAreasAndPoints: Bool,
        coarserLevels: Bool = false,
        resolution: Int? = nil,
        tick: () throws -> Void,
        emit: (ElementDumper.Kind, Int, [Coord], Int) -> Void
    ) throws {
        let directory = ImgContainer.directory(of: img)
        let tiles = directory.filter { $0.ext.uppercased() == "TRE" }
        guard !tiles.isEmpty else { throw Trouble.noTiles }
        for tre in tiles {
            guard
                let rgn = directory.first(where: {
                    $0.name == tre.name && $0.ext.uppercased() == "RGN"
                })
            else { continue }
            guard let treData = ImgContainer.read(tre, from: img),
                let rgnData = ImgContainer.read(rgn, from: img)
            else { continue }
            let tree = try Tree(treData, tile: tre.name)
            let region = try Region(rgnData, tile: tre.name)
            // Level 0 is the most detailed; it is named by that number, not by its
            // position in the list. `coarserLevels` reads everything above it instead:
            // the zoomed-out drawings, where a style may keep what it never draws up
            // close - a reserve's hatch over half a district.
            for division in tree.subdivisions
            where resolution.map({ 24 - division.shift == $0 })
                ?? (coarserLevels ? division.level > 0 : division.level == 0)
            {
                guard grounds.contains(where: { division.near($0) }) else { continue }
                try region.read(
                    division,
                    extendedAreasAndPoints: extendedAreasAndPoints,
                    tile: tre.name
                ) { kind, type, coords in
                    try tick()
                    guard coords.contains(where: { c in grounds.contains { $0.contains(c) } })
                    else { return }
                    emit(kind, type, coords, 24 - division.shift)
                }
            }
        }
    }

    // MARK: Bytes

    /// A cursor over a subfile's bytes, little-endian, with the three-byte reads the
    /// format is made of. An array, so the bit reader can look into it by offset with
    /// nothing borrowed from a closure.
    /// Every offset and length comes from the file, so a read past the end answers zero
    /// and raises `overran` rather than trapping; the caller checks it per record.
    struct Bytes {
        let bytes: [UInt8]
        var position = 0
        private(set) var overran = false

        init(_ data: Data) { bytes = [UInt8](data) }

        var count: Int { bytes.count }

        func u8(at offset: Int) -> UInt8 { offset >= 0 && offset < bytes.count ? bytes[offset] : 0 }
        func u16(at offset: Int) -> UInt16 {
            UInt16(u8(at: offset)) | UInt16(u8(at: offset + 1)) << 8
        }
        func u32(at offset: Int) -> UInt32 {
            UInt32(u16(at: offset)) | UInt32(u16(at: offset + 2)) << 16
        }

        mutating func u8() -> UInt8 { u8(at: take(1)) }
        mutating func u16() -> UInt16 { u16(at: take(2)) }
        mutating func s16() -> Int16 { Int16(bitPattern: u16()) }
        mutating func u24() -> UInt32 {
            let at = take(3)
            return UInt32(u8(at: at)) | UInt32(u8(at: at + 1)) << 8 | UInt32(u8(at: at + 2)) << 16
        }
        mutating func s24() -> Int32 {
            let raw = u24()
            return raw & 0x800000 != 0 ? Int32(bitPattern: raw | 0xFF000000) : Int32(raw)
        }
        mutating func u32() -> UInt32 { u32(at: take(4)) }

        /// Steps over `count` bytes and says where they began, for the bit reader.
        mutating func take(_ count: Int) -> Int {
            let at = position
            position += count
            if at < 0 || position > bytes.count { overran = true }
            return at
        }
    }

    /// mkgmap's BitReader: bits taken from the low end of each byte first.
    struct BitReader {
        private let bytes: [UInt8]
        private let base: Int
        /// One past the last byte the stream may read; a bit past it reads as zero and
        /// raises `overran`.
        private let end: Int
        private(set) var position = 0
        private(set) var overran = false

        init(_ bytes: [UInt8], from base: Int, length: Int = Int.max) {
            self.bytes = bytes
            self.base = max(0, base)
            self.end = min(bytes.count, length == Int.max ? bytes.count : base + length)
        }

        private mutating func byte(at index: Int) -> Int {
            guard index >= 0, index < end else { overran = true; return 0 }
            return Int(bytes[index])
        }

        mutating func get1() -> Bool {
            let byte = byte(at: base + position / 8)
            let off = position % 8
            position += 1
            return (byte >> off) & 1 == 1
        }

        mutating func get(_ n: Int) -> Int {
            var result = 0
            var got = 0
            while got < n {
                let off = position % 8
                let byte = byte(at: base + position / 8) >> off
                var take = n - got
                if take > 8 - off { take = 8 - off }
                let mask = (1 << take) - 1
                result |= (byte & mask) << got
                got += take
                position += take
            }
            return result
        }

        /// A signed delta with mkgmap's escape: the most negative value means "add the
        /// rest of the range and read another".
        mutating func sget2(_ n: Int) -> Int {
            let top = 1 << (n - 1)
            let mask = top - 1
            var base = 0
            var result = get(n)
            while result == top {
                base += mask
                result = get(n)
            }
            if result & top == 0 {
                result += base
            } else {
                result = (result | ~mask) - base
            }
            return result
        }
    }
}
