import Foundation

/// A compiled Garmin TYP, read back into its parts.
///
/// The layout follows mkgmap's own writer (`uk.me.parabola.imgfmt.app.typ.*`). Each
/// element must end exactly where the next one in its index begins; one that does not is
/// kept with `exact` false rather than dropped.
struct TypBinary {

    struct Element {
        let kind: MapElementKind
        let type: Int
        let subtype: Int

        /// The code as the rule files and the TYP source write it.
        ///
        /// A point always folds its subtype in: `Type=0x2a00` is type 0x2a, subtype 0. A
        /// line or polygon folds it in only for an extended type, one above 0xFF, written
        /// as five digits: `Type=0x10208` is type 0x102, subtype 0x08.
        var code: Int {
            kind == .point || type > 0xFF ? (type << 8) | subtype : type
        }

        /// Day ink, day background, night ink, night background — as many as the element
        /// stores. A nil is a slot the file marks transparent and does not store at all.
        let colours: [String?]

        /// Palette indices per pixel, for an element that carries a pattern.
        let bitmap: [[Int]]?
        /// Rows of the pattern, which for a line is its thickness.
        let bitmapHeight: Int

        /// A point's own images, which carry their own palettes rather than the element's.
        let dayImage: PointImage?
        let nightImage: PointImage?

        let labels: [(language: Int, text: String)]
        let fontStyle: String?
        let dayLabelColour: String?
        let nightLabelColour: String?

        let lineWidth: Int?
        let borderWidth: Int?
        let usesOrientation: Bool

        /// False when the element did not end where the next one begins. Its colours and
        /// labels may still be right; nothing downstream should assume so.
        let exact: Bool
    }

    /// One image of a point, palette and pixels together.
    struct PointImage {
        let width: Int
        let height: Int
        /// nil entries are transparent.
        let palette: [String?]
        /// Indices into `palette`.
        let pixels: [[Int]]
    }

    let codePage: Int
    let familyID: Int
    let productID: Int
    let polygons: [Element]
    let lines: [Element]
    let points: [Element]
    let drawOrder: [(code: Int, level: Int)]

    /// How many elements ended exactly where the index says they should.
    var exactCount: Int { all.filter(\.exact).count }
    var all: [Element] { polygons + lines + points }

    func elements(_ kind: MapElementKind) -> [Element] {
        switch kind {
        case .polygon: return polygons
        case .line: return lines
        case .point: return points
        }
    }

    // MARK: Reading

    enum ReadError: LocalizedError {
        case notATyp
        case truncated

        var errorDescription: String? {
            switch self {
            case .notATyp: return t("not a TYP file — the GARMIN TYP signature is missing")
            case .truncated: return t("the TYP ends in the middle of its header")
            }
        }
    }

    static func read(_ url: URL) throws -> TypBinary {
        guard let data = try? Data(contentsOf: url) else { throw ReadError.truncated }
        return try decode([UInt8](data))
    }

    static func decode(_ data: [UInt8]) throws -> TypBinary {
        guard data.count > 0x5B else { throw ReadError.truncated }
        guard Array(data[2..<12]) == Array("GARMIN TYP".utf8) else { throw ReadError.notATyp }

        var header = Cursor(data, at: 0x15)
        let codePage = header.u2()
        let pointData = (header.u4(), header.u4())
        let lineData = (header.u4(), header.u4())
        let polygonData = (header.u4(), header.u4())
        let familyID = header.u2()
        let productID = header.u2()
        let pointIndex = (header.u4(), header.u2(), header.u4())
        let lineIndex = (header.u4(), header.u2(), header.u4())
        let polygonIndex = (header.u4(), header.u2(), header.u4())
        let drawOrderSection = (header.u4(), header.u2(), header.u4())

        func read(_ kind: MapElementKind,
                  _ index: (Int, Int, Int),
                  _ section: (Int, Int)) -> [Element] {
            entries(in: data, index: index, section: section).compactMap { entry in
                decodeElement(kind, data, at: entry.offset, length: entry.length,
                              type: entry.type, subtype: entry.subtype, codePage: codePage)
            }
        }

        return TypBinary(
            codePage: codePage, familyID: familyID, productID: productID,
            polygons: read(.polygon, polygonIndex, polygonData),
            lines: read(.line, lineIndex, lineData),
            points: read(.point, pointIndex, pointData),
            drawOrder: decodeDrawOrder(data, drawOrderSection))
    }

    /// Index entries resolved to absolute offsets and lengths. An entry holds
    /// `type << 5 | subtype` and an offset of `itemSize - 2` bytes; lengths come from the
    /// gap to the next entry once they are in offset order.
    private static func entries(in data: [UInt8], index: (Int, Int, Int),
                                section: (Int, Int))
        -> [(type: Int, subtype: Int, offset: Int, length: Int)] {
        let (position, itemSize, length) = index
        guard itemSize >= 3, length > 0 else { return [] }
        let pointerSize = itemSize - 2

        var raw: [(type: Int, subtype: Int, offset: Int)] = []
        for i in 0..<(length / itemSize) {
            var cursor = Cursor(data, at: position + i * itemSize)
            guard cursor.has(itemSize) else { break }
            let packed = cursor.u2()
            let offset = cursor.un(pointerSize)
            raw.append((packed >> 5, packed & 0x1F, offset))
        }
        raw.sort { $0.offset < $1.offset }

        let (start, sectionLength) = section
        return raw.enumerated().map { i, entry in
            let end = i + 1 < raw.count ? raw[i + 1].offset : sectionLength
            return (entry.type, entry.subtype, start + entry.offset, end - entry.offset)
        }
    }

    private static func decodeDrawOrder(_ data: [UInt8],
                                        _ section: (Int, Int, Int)) -> [(code: Int, level: Int)] {
        let (position, itemSize, length) = section
        guard itemSize > 0, length > 0 else { return [] }
        var out: [(code: Int, level: Int)] = []
        var level = 1
        for i in 0..<(length / itemSize) {
            var cursor = Cursor(data, at: position + i * itemSize)
            guard cursor.has(5) else { break }
            let type = cursor.u1()
            let subtypes = cursor.u4()
            if type == 0 { level += 1; continue }
            if subtypes == 0 {
                out.append((type, level))
            } else {
                // A non-zero mask means extended types: the record's byte is the low byte
                // of the type, and each set bit is one subtype under it.
                for bit in 0..<32 where subtypes & (1 << bit) != 0 {
                    out.append((((0x100 | type) << 8) | bit, level))
                }
            }
        }
        return out
    }

    // MARK: Labels

    static func decodeLabels(_ blob: [UInt8],
                                     codePage: Int) -> [(language: Int, text: String)] {
        var out: [(language: Int, text: String)] = []
        var i = 0
        while i < blob.count {
            let language = Int(blob[i])
            i += 1
            var end = i
            while end < blob.count, blob[end] != 0 { end += 1 }
            let bytes = Array(blob[i..<end])
            let text = CodePage.decodeLenient(bytes, codePage: codePage)
            out.append((language, text))
            i = end + 1
        }
        return out
    }

    struct FontInfo {
        let style: String?
        let day: String?
        let night: String?
        static let none = FontInfo(style: nil, day: nil, night: nil)
    }

    fileprivate static let fontStyles = [0: "Default", 1: "NoLabel", 2: "SmallFont",
                                         3: "NormalFont", 4: "LargeFont"]

    // MARK: A little-endian cursor

    struct Cursor {
        let data: [UInt8]
        var position: Int

        init(_ data: [UInt8], at position: Int) {
            self.data = data
            self.position = position
        }

        func has(_ count: Int) -> Bool { position + count <= data.count }

        mutating func u1() -> Int {
            guard position < data.count else { position += 1; return 0 }
            defer { position += 1 }
            return Int(data[position])
        }

        mutating func u2() -> Int {
            let a = u1(), b = u1()
            return a | (b << 8)
        }

        mutating func u4() -> Int {
            let a = u2(), b = u2()
            return a | (b << 16)
        }

        mutating func un(_ count: Int) -> Int {
            var value = 0
            for i in 0..<count { value |= u1() << (8 * i) }
            return value
        }

        mutating func raw(_ count: Int) throws -> [UInt8] {
            guard count >= 0, has(count) else { throw ReadError.truncated }
            defer { position += count }
            return Array(data[position..<(position + count)])
        }

        /// A colour is stored blue, green, red.
        mutating func rgb() throws -> String {
            let bytes = try raw(3)
            return String(format: "#%02X%02X%02X", bytes[2], bytes[1], bytes[0])
        }

        /// Reads only the slots the file actually stores, leaving the rest transparent.
        mutating func colours(_ transparent: [Bool]) throws -> [String?] {
            var out: [String?] = []
            for isTransparent in transparent {
                out.append(isTransparent ? nil : try rgb())
            }
            return out
        }

        /// Rows are byte aligned and bits packed low end first. For the one-bit palettes of
        /// lines and polygons the stored bit is the complement of the palette index
        /// (`ColourInfo.getIndex` inverts it), so a set bit means the first colour.
        mutating func bitmap(width: Int, height: Int, bitsPerPixel: Int) throws -> [[Int]] {
            let rowBytes = (width * bitsPerPixel + 7) / 8
            var rows: [[Int]] = []
            for _ in 0..<height {
                let bytes = try raw(rowBytes)
                var row: [Int] = []
                row.reserveCapacity(width)
                for x in 0..<width {
                    let bit = x * bitsPerPixel
                    let value = (Int(bytes[bit / 8]) >> (bit % 8)) & ((1 << bitsPerPixel) - 1)
                    row.append(bitsPerPixel == 1 ? 1 - value : value)
                }
                rows.append(row)
            }
            return rows
        }

        /// A point's image: its own palette, then its pixels. Mode 0x20 packs each colour
        /// into 28 unaligned bits — blue, green, red, four of alpha; mode 0x10 stores solid
        /// colours and appends one transparent slot; anything else is solid colours alone.
        mutating func pointImage(width: Int, height: Int) throws -> TypBinary.PointImage {
            let solidCount = u1()
            let mode = u1()
            var palette: [String?] = []
            var count = solidCount

            if mode == 0x20 {
                let bytes = try raw((solidCount * 28 + 7) / 8)
                for i in 0..<solidCount {
                    let start = i * 28
                    var value = 0
                    for bit in 0..<28 {
                        let absolute = start + bit
                        let set = (Int(bytes[absolute / 8]) >> (absolute % 8)) & 1
                        value |= set << bit
                    }
                    let blue = value & 0xFF
                    let green = (value >> 8) & 0xFF
                    let red = (value >> 16) & 0xFF
                    let alpha = (value >> 24) & 0xF
                    palette.append(alpha == 0 ? nil
                                   : String(format: "#%02X%02X%02X", red, green, blue))
                }
            } else if mode == 0x10 {
                for _ in 0..<solidCount { palette.append(try rgb()) }
                palette.append(nil)
                count = solidCount + 1
            } else {
                for _ in 0..<solidCount { palette.append(try rgb()) }
            }

            let bitsPerPixel = TypBinary.bitsPerPixel(forColours: count)
            var pixels = try bitmap(width: width, height: height, bitsPerPixel: bitsPerPixel)
            // A point image indexes its palette directly; `bitmap` inverts one-bit values
            // for the line and polygon patterns, so that has to be undone here.
            if bitsPerPixel == 1 {
                pixels = pixels.map { $0.map { 1 - $0 } }
            }
            return TypBinary.PointImage(width: width, height: height,
                                        palette: palette, pixels: pixels)
        }

        mutating func labelBlock() throws -> [UInt8] {
            guard position < data.count else { throw ReadError.truncated }
            // Self-describing prefix: bit 0 set means one byte holding len<<1, otherwise
            // two bytes holding len<<2.
            let length = data[position] & 1 == 1 ? (u1() >> 1) : (u2() >> 2)
            return try raw(max(0, length))
        }

        mutating func fontInfo() throws -> FontInfo {
            let b = u1()
            var day: String?
            var night: String?
            if b & 8 != 0 { day = try rgb() }
            if b & 0x10 != 0 { night = try rgb() }
            if (b & 0x60) == 0x60 {
                _ = u1()
                _ = try rgb()
                _ = try rgb()
            } else if b & 0x60 != 0 {
                throw ReadError.truncated
            }
            if b & 0x80 != 0 { throw ReadError.truncated }
            return FontInfo(style: TypBinary.fontStyles[b & 7], day: day, night: night)
        }
    }

    static func bitsPerPixel(forColours count: Int) -> Int {
        if count == 0 { return 24 }
        if count < 2 { return 1 }
        if count < 4 { return 2 }
        if count < 16 { return 4 }
        return 8
    }
}
