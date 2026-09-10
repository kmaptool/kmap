import Foundation

/// A compiled map's elements, read with kmap's own reader (`ImgElements`) into one
/// flat table in the map's own coordinates.
///
/// The binary form `write` produces matches, byte for byte, the Java helper compiled
/// against mkgmap.jar that this replaced.
enum ElementDumper {

    enum Kind: Character {
        case point = "P", line = "L", area = "A"

        /// Its place in a key, and the byte written for it in a dump.
        var slot: Int {
            switch self {
            case .point: return 0
            case .line: return 1
            case .area: return 2
            }
        }

        /// The same kind as the style side names it.
        var styleKind: MapElementKind {
            switch self {
            case .point: return .point
            case .line: return .line
            case .area: return .polygon
            }
        }

        /// From the byte written for it in a dump.
        init?(byte: UInt8) {
            switch byte {
            case 0: self = .point
            case 1: self = .line
            case 2: self = .area
            default: return nil
            }
        }
    }

    /// One element: what it is, and where its vertex chain sits in the dump's cells.
    struct Element: Sendable {
        let kind: Kind
        let type: Int
        let from: Int32
        let count: Int32
    }

    /// Every element of a map, as one table.
    ///
    /// One array of packed cells with a range per element, rather than an array per
    /// element: a country-sized map holds tens of millions of them.
    struct Dump: Sendable {
        var elements: [Element] = []
        var cells: [UInt64] = []
        /// The resolution each element is drawn at, where the walk recorded it. Held
        /// beside the elements rather than inside them: the binary dump's shape is a
        /// byte-compare anchor and does not change.
        var resolutions: [Int16] = []
        var count: Int { elements.count }

        func resolution(_ at: Int) -> Int? {
            at < resolutions.count ? Int(resolutions[at]) : nil
        }

        /// The vertex chain of one element.
        func chain(_ at: Int) -> ArraySlice<UInt64> {
            let element = elements[at]
            return cells[Int(element.from)..<Int(element.from + element.count)]
        }
    }

    /// Dumps every element of every tile that reaches the ground being searched.
    /// - Parameter grounds: one rectangle per extract, not the box around them all;
    ///   elements outside every rectangle are skipped.
    /// - Parameter coarserLevels: read the zoomed-out levels instead of the detailed
    ///   one — where a style may keep what it never draws up close.
    static func dump(img: URL, grounds: [BBox], log: Log,
                     coarserLevels: Bool = false,
                     progress: RecoverProgress? = nil) throws -> Dump {
        var dump = Dump()
        var seen = 0
        // Extended-type polygons and points too: a third-party style may keep whole
        // classes of feature on an extended code.
        try ImgElements.read(img: img, grounds: grounds.map(ImgElements.Ground.init),
                             extendedAreasAndPoints: true,
                             coarserLevels: coarserLevels,
                             tick: {
                                 seen += 1
                                 if seen % 20000 == 0 {
                                     try Task.checkCancellation()
                                     progress?.count(seen)
                                 }
                             }) { kind, type, coords, resolution in
            let from = dump.cells.count
            for c in coords { dump.cells.append(GarminGrid.pack(latUnit: c.lat, lonUnit: c.lon)) }
            dump.elements.append(Element(kind: kind, type: type,
                                         from: Int32(from), count: Int32(coords.count)))
            dump.resolutions.append(Int16(resolution))
        }
        return dump
    }

    /// Writes the dump in its binary form: per element one kind byte, then type and vertex
    /// count as little-endian Int32, then each vertex as latitude and longitude Int32.
    static func write(_ dump: Dump, to url: URL) throws {
        var out = Data()
        out.reserveCapacity(dump.elements.count * 9 + dump.cells.count * 8)
        func put(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        for (at, element) in dump.elements.enumerated() {
            out.append(UInt8(element.kind.slot))
            put(Int32(element.type))
            put(element.count)
            for cell in dump.chain(at) {
                put(Int32(bitPattern: UInt32(cell >> 32)))
                put(Int32(bitPattern: UInt32(cell & 0xFFFF_FFFF)))
            }
        }
        try out.write(to: url, options: .atomic)
    }

    static func parse(_ url: URL) throws -> Dump {
        var dump = Dump()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        data.withUnsafeBytes { raw in
            let end = raw.count
            var at = 0
            // A guess at the shape, so neither array is regrown many times.
            dump.elements.reserveCapacity(end / 48)
            dump.cells.reserveCapacity(end / 8)
            while at + 9 <= end {
                guard let kind = Kind(byte: raw.load(fromByteOffset: at, as: UInt8.self)) else {
                    break
                }
                let type = Int(Int32(littleEndian:
                    raw.loadUnaligned(fromByteOffset: at + 1, as: Int32.self)))
                let count = Int(Int32(littleEndian:
                    raw.loadUnaligned(fromByteOffset: at + 5, as: Int32.self)))
                at += 9
                guard count > 0, at + count * 8 <= end else { break }
                let from = dump.cells.count
                for vertex in 0..<count {
                    let lat = Int32(littleEndian:
                        raw.loadUnaligned(fromByteOffset: at + vertex * 8, as: Int32.self))
                    let lon = Int32(littleEndian:
                        raw.loadUnaligned(fromByteOffset: at + vertex * 8 + 4, as: Int32.self))
                    dump.cells.append(GarminGrid.pack(latUnit: lat, lonUnit: lon))
                }
                at += count * 8
                dump.elements.append(Element(kind: kind, type: type,
                                             from: Int32(from), count: Int32(count)))
            }
        }
        return dump
    }
}
