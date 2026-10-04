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

        /// Day ink, day background, night ink, night background - as many as the element
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

        func read(
            _ kind: MapElementKind,
            _ index: (Int, Int, Int),
            _ section: (Int, Int)
        ) -> [Element] {
            entries(in: data, index: index, section: section).compactMap { entry in
                decodeElement(
                    kind,
                    data,
                    at: entry.offset,
                    length: entry.length,
                    type: entry.type,
                    subtype: entry.subtype,
                    codePage: codePage
                )
            }
        }

        return TypBinary(
            codePage: codePage,
            familyID: familyID,
            productID: productID,
            polygons: read(.polygon, polygonIndex, polygonData),
            lines: read(.line, lineIndex, lineData),
            points: read(.point, pointIndex, pointData),
            drawOrder: decodeDrawOrder(data, drawOrderSection)
        )
    }

    /// Index entries resolved to absolute offsets and lengths. An entry holds
    /// `type << 5 | subtype` and an offset of `itemSize - 2` bytes; lengths come from the
    /// gap to the next entry once they are in offset order.
    private static func entries(
        in data: [UInt8],
        index: (Int, Int, Int),
        section: (Int, Int)
    ) -> [(type: Int, subtype: Int, offset: Int, length: Int)] {
        let (position, itemSize, length) = index
        // Two bytes of type and up to four of offset: a wider pointer is not a TYP's.
        guard itemSize >= 3, itemSize <= 6, length > 0 else { return [] }
        let pointerSize = itemSize - 2

        var raw: [(type: Int, subtype: Int, offset: Int)] = []
        for i in 0..<(length / itemSize) {
            var cursor = Cursor(data, at: position + i * itemSize)
            guard cursor.has(itemSize) else { break }
            let packed = cursor.u2()
            let offset = cursor.un(pointerSize)
            guard offset >= 0, offset <= section.1 else { continue }
            raw.append((packed >> 5, packed & 0x1F, offset))
        }
        raw.sort { $0.offset < $1.offset }

        let (start, sectionLength) = section
        return raw.enumerated().map { i, entry in
            let end = i + 1 < raw.count ? raw[i + 1].offset : sectionLength
            return (entry.type, entry.subtype, start + entry.offset, end - entry.offset)
        }
    }

    private static func decodeDrawOrder(
        _ data: [UInt8],
        _ section: (Int, Int, Int)
    ) -> [(code: Int, level: Int)] {
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

    static func decodeLabels(
        _ blob: [UInt8],
        codePage: Int
    ) -> [(language: Int, text: String)] {
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

    static func bitsPerPixel(forColours count: Int) -> Int {
        if count == 0 { return 24 }
        if count < 2 { return 1 }
        if count < 4 { return 2 }
        if count < 16 { return 4 }
        return 8
    }
}
