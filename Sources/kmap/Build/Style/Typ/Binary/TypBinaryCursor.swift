import Foundation

extension TypBinary {
    /// A little-endian cursor over the file's bytes.
    struct Cursor {
        private static let fontStyles = [
            0: "Default", 1: "NoLabel", 2: "SmallFont",
            3: "NormalFont", 4: "LargeFont"
        ]

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
        /// into 28 unaligned bits - blue, green, red, four of alpha; mode 0x10 stores solid
        /// colours and appends one transparent slot; anything else is solid colours alone.
        mutating func pointImage(width: Int, height: Int) throws -> TypBinary.PointImage {
            let solidCount = u1()
            let mode = u1()
            if solidCount == 0 { return try trueColourImage(width: width, height: height, mode: mode) }
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
                    // Transparency, as mkgmap writes it: 0 opaque, 15 clear. Half way or
                    // more reads as clear, the threshold an imported icon is cut at.
                    let transparency = (value >> 24) & 0xF
                    palette.append(
                        transparency >= 8
                            ? nil
                            : String(format: "#%02X%02X%02X", red, green, blue)
                    )
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
            return TypBinary.PointImage(width: width, height: height, palette: palette, pixels: pixels)
        }

        /// The most colours a palette image holds: 8 bits a pixel. Of them 255 at most are
        /// solid, the count of solid ones being a byte where 0 says true colour.
        static let mostPaletteColours = 256
        static let mostSolidColours = 255

        /// An image with no palette, as mkgmap's TrueImage writes it: blue, green, red per
        /// pixel in 1 run of bits, plus 4 bits of transparency in mode 0x20; mode 0x10 names
        /// its clear colour first. Read as the palette of its colours, empty if too many.
        mutating func trueColourImage(width: Int, height: Int, mode: Int) throws -> TypBinary.PointImage {
            var clear: (Int, Int, Int)?
            if mode == 0x10 { clear = (u1(), u1(), u1()) }
            let bitsEach = mode == 0x20 ? 28 : 24
            let bytes = try raw((width * height * bitsEach + 7) / 8)
            func bits(_ start: Int, _ count: Int) -> Int {
                var value = 0
                for bit in 0..<count {
                    let at = start + bit
                    value |= ((Int(bytes[at / 8]) >> (at % 8)) & 1) << bit
                }
                return value
            }
            var palette: [String?] = []
            var slots: [String: Int] = [:]
            var pixels: [[Int]] = []
            pixels.reserveCapacity(height)
            for y in 0..<height {
                var row: [Int] = []
                row.reserveCapacity(width)
                for x in 0..<width {
                    let start = (y * width + x) * bitsEach
                    let blue = bits(start, 8), green = bits(start + 8, 8), red = bits(start + 16, 8)
                    // Half transparent or more reads as clear, as in a mode 0x20 palette.
                    let isClear =
                        mode == 0x20
                        ? bits(start + 24, 4) >= 8
                        : clear.map { $0 == (blue, green, red) } ?? false
                    let colour = isClear ? nil : String(format: "#%02X%02X%02X", red, green, blue)
                    let key = colour ?? "none"
                    if let slot = slots[key] {
                        row.append(slot)
                    } else {
                        slots[key] = palette.count
                        row.append(palette.count)
                        palette.append(colour)
                    }
                }
                pixels.append(row)
            }
            guard palette.count <= Self.mostPaletteColours,
                palette.filter({ $0 != nil }).count <= Self.mostSolidColours
            else {
                return TypBinary.PointImage(width: width, height: height, palette: [], pixels: pixels)
            }
            return TypBinary.PointImage(width: width, height: height, palette: palette, pixels: pixels)
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
            return FontInfo(style: Self.fontStyles[b & 7], day: day, night: night)
        }
    }
}
