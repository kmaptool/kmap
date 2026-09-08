import Foundation

/// Writes a Garmin Custom POI file (`.gpi`).
///
/// A Garmin `.img` POI record has no description field, and a `.gpi` does: it is the one
/// Garmin format that carries a multi-line note the device will show. The file is a tree
/// of records, each `tag, flags, size` and then a payload that may hold further records:
///
///     0   the file header: format marker, when it was made, what it is called
///     1   what kind of file this is, and the code page its text is written in
///     9   a category — the heading the device files these points under
///       8   the group, with the box around every point in it
///         2   one point: where it is, and its name
///           4   which bitmap draws it, where one is carried
///          10   its description
///     5   the bitmap itself, where the points are to be drawn on the map
///
/// Sizes count the payload. Offsets inside the bitmap count from the start of its record,
/// header included. A record whose flags carry 8 states, in a further `u32`, how much of
/// its payload is its own before the records nested at the end of it.
enum GPIFile {

    struct Point {
        var lat: Double
        var lon: Double
        /// Already in the file's code page.
        var name: [UInt8]
        /// Already in the file's code page. Empty takes the name, as a device shows
        /// something either way.
        var description: [UInt8]
    }

    /// The picture a point is drawn with, where the points are to appear on the map.
    ///
    /// Eight bits a pixel, top row first, indices into `palette`; a palette entry is
    /// blue, green, red, zero. `transparent` is the colour the device draws nothing for.
    struct Icon {
        var width: Int
        var height: Int
        var pixels: [UInt8]
        var palette: [(red: UInt8, green: UInt8, blue: UInt8)]
        var transparent: UInt32 = 0x00ff_00ff
    }

    /// Garmin counts time from the start of 1990 rather than 1970.
    static let epoch = Date(timeIntervalSince1970: 631_065_600)

    /// Degrees to the 2^32-per-turn unit Garmin stores coordinates in.
    static func semicircles(_ degrees: Double) -> Int32 {
        let scaled = (degrees * (2147483648.0 / 180.0)).rounded()
        return Int32(max(-2147483648, min(2147483647, scaled)))
    }

    /// - Parameters:
    ///   - category: the heading the device files these points under, in the code page.
    ///   - codePage: the number written into the file, so the device decodes the text as
    ///     it was written.
    ///   - fileName: what the file calls itself inside, which is not its name on disk.
    ///   - icon: nil leaves the points out of the map, listed under Custom POI only.
    ///
    /// Points are written in name order, which is the order a device lists them in;
    /// two of the same name keep the order they were given in.
    static func data(points: [Point], category: [UInt8], codePage: Int,
                     fileName: String, icon: Icon? = nil,
                     madeAt: Date = Date()) -> Data {
        let points = sorted(points)
        var out = Data()
        out += record(0, payload: header(fileName: fileName, madeAt: madeAt))
        out += record(1, payload: kind(codePage: codePage))
        out += categoryRecord(points: points, category: category, icon: icon)
        // What ends the file: a tag no reader knows, and a length of nothing.
        out += Data([0xff, 0xff, 0, 0, 0, 0, 0, 0])
        return out
    }

    /// By name, comparing the code page's own bytes rather than the letters they stand
    /// for: the device reads bytes. Stable, so the input order settles a tie.
    static func sorted(_ points: [Point]) -> [Point] {
        points.enumerated()
            .sorted { a, b in
                if a.element.name != b.element.name {
                    return before(a.element.name, b.element.name)
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    private static func before(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }

    // MARK: The records

    private static func header(fileName: String, madeAt: Date) -> Data {
        var out = Data("GRMREC00".utf8)
        out += u32(UInt32(max(0, madeAt.timeIntervalSince(epoch))))
        out += u16(0)
        let name = Array(fileName.utf8)
        out += u16(UInt16(name.count))
        out += Data(name)
        return out
    }

    private static func kind(codePage: Int) -> Data {
        var out = Data("POI".utf8)
        out += Data([0, 0, 0])
        out += Data("00".utf8)
        out += u16(UInt16(truncatingIfNeeded: codePage))
        out += u16(0)
        return out
    }

    private static func categoryRecord(points: [Point], category: [UInt8],
                                       icon: Icon?) -> Data {
        var own = strings(category)
        for group in groups(of: points) {
            own += groupRecord(points: group, drawn: icon != nil)
        }
        // The bitmap sits after the group, and outside the part the category calls its own.
        var payload = own
        if let icon { payload += record(5, payload: bitmap(icon)) }
        return record(9, payload: payload, ownSize: own.count)
    }

    /// How many points one group holds before it is worth cutting in four.
    private static let groupLimit = 128

    /// Cuts the points into groups small enough for a device to skip a whole group by its
    /// box alone: while a group holds more than ``groupLimit``, it is split at the mean
    /// of its own points into four quadrants, north-west first, and each is cut again.
    ///
    /// A split that puts everything back in one quadrant stops, so points in one place
    /// cannot recurse forever.
    static func groups(of points: [Point]) -> [[Point]] {
        guard points.count > groupLimit else { return [points] }
        var latSum = 0, lonSum = 0
        for point in points {
            latSum += Int(semicircles(point.lat))
            lonSum += Int(semicircles(point.lon))
        }
        let midLat = Int32(latSum / points.count), midLon = Int32(lonSum / points.count)

        var quadrants: [[Point]] = [[], [], [], []]
        for point in points {
            let north = semicircles(point.lat) >= midLat
            let east = semicircles(point.lon) >= midLon
            // North-west, north-east, south-west, south-east.
            quadrants[(north ? 0 : 2) + (east ? 1 : 0)].append(point)
        }
        guard quadrants.allSatisfy({ $0.count < points.count }) else { return [points] }
        return quadrants.flatMap { $0.isEmpty ? [] : groups(of: $0) }
    }

    /// The group: the box around every point in it, then the points.
    private static func groupRecord(points: [Point], drawn: Bool) -> Data {
        var box = Data()
        let lats = points.map { semicircles($0.lat) }
        let lons = points.map { semicircles($0.lon) }
        box += i32(lats.max() ?? 0)
        box += i32(lons.max() ?? 0)
        box += i32(lats.min() ?? 0)
        box += i32(lons.min() ?? 0)
        box += u32(0)
        box += u16(1)
        box += Data([0])

        var payload = box
        for point in points { payload += pointRecord(point, drawn: drawn) }
        return record(8, payload: payload, ownSize: box.count)
    }

    private static func pointRecord(_ point: Point, drawn: Bool) -> Data {
        var own = i32(semicircles(point.lat))
        own += i32(semicircles(point.lon))
        own += Data([1])
        own += u16(0)
        own += strings(point.name)

        var payload = own
        // Which bitmap draws it. There is one, so it is the first.
        if drawn { payload += record(4, payload: u16(0)) }
        payload += record(10, payload: strings(point.description.isEmpty ? point.name
                                                                        : point.description))
        return record(2, payload: payload, ownSize: own.count)
    }

    private static func bitmap(_ icon: Icon) -> Data {
        let stride = icon.width
        let imageBytes = stride * icon.height
        // Offsets are counted from the start of the record, its eight-byte header included.
        let headerSize = 8 + 36
        var out = u16(0)
        out += u16(UInt16(icon.width))
        out += u16(UInt16(icon.height))
        out += u16(UInt16(stride))
        out += u16(8)
        out += u16(0)
        out += u32(UInt32(imageBytes))
        out += u32(UInt32(headerSize))
        out += u32(UInt32(icon.palette.count))
        out += u32(icon.transparent)
        out += u32(1)
        out += u32(UInt32(headerSize + imageBytes))

        var pixels = icon.pixels
        pixels += [UInt8](repeating: 0, count: max(0, imageBytes - pixels.count))
        out += Data(pixels.prefix(imageBytes))
        for colour in icon.palette {
            out += Data([colour.blue, colour.green, colour.red, 0])
        }
        return out
    }

    // MARK: Pieces

    /// A list of texts by language. One language, since a map is built in one.
    private static func strings(_ text: [UInt8], language: String = "EN") -> Data {
        var block = Data(language.utf8.prefix(2))
        block += u16(UInt16(text.count))
        block += Data(text)
        return u32(UInt32(block.count)) + block
    }

    /// - Parameter ownSize: how much of the payload belongs to the record itself, where
    ///   records are nested at the end of it. Absent means all of it.
    private static func record(_ tag: UInt16, payload: Data, ownSize: Int? = nil) -> Data {
        var out = u16(tag)
        out += u16(ownSize == nil ? 0 : 8)
        out += u32(UInt32(payload.count))
        if let ownSize { out += u32(UInt32(ownSize)) }
        return out + payload
    }

    private static func u16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func u32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func i32(_ value: Int32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

extension GPIFile.Icon {
    /// The mark kmap draws its own points with: a filled disc with a white ring, on the
    /// magenta the format takes as nothing at all.
    ///
    /// Drawn rather than stored, so there is no artwork to carry and no size to keep in
    /// step with the code that reads it.
    static var dot: GPIFile.Icon {
        let side = 24
        let centre = Double(side - 1) / 2
        let outer = Double(side) / 2 - 1.5
        let inner = outer - 2.5
        var pixels = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) - centre, dy = Double(y) - centre
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance <= inner {
                    pixels[y * side + x] = 1
                } else if distance <= outer {
                    pixels[y * side + x] = 2
                }
            }
        }
        return GPIFile.Icon(
            width: side, height: side, pixels: pixels,
            // 0 is the colour the device draws nothing for, and has to be the one named
            // as transparent below.
            palette: [(red: 0xff, green: 0x00, blue: 0xff),
                      (red: 0x1f, green: 0x6f, blue: 0xd0),
                      (red: 0xff, green: 0xff, blue: 0xff)])
    }
}
