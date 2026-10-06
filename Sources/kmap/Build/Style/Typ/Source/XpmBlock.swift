import Foundation

/// An `Xpm=` block: a list of solid colours, or a bitmap.
///
/// The header is four numbers: width, height, colour count, characters per pixel. A width of
/// zero means colours only. Their roles depend on the element: day and night fill for a
/// polygon; day fill, day casing, night fill, night casing for a line with a border.
struct XpmBlock: Equatable {
    let width: Int
    let height: Int
    let declaredColours: Int
    let charsPerPixel: Int

    /// Palette in declaration order. A nil colour is `none` - transparent, and drawn as
    /// whatever lies beneath.
    let palette: [(key: String, colour: String?)]

    /// The pixel rows, verbatim, `charsPerPixel` characters per pixel.
    let rows: [String]

    /// True when this carries colours only and no picture.
    var isSolid: Bool { width == 0 || height == 0 }

    /// Garmin icons stop at 255 x 255 and patterns at 32 wide; a million cells is past
    /// anything a file could mean.
    static let mostPixels = 1 << 20

    /// Colours in declaration order, transparency included as nil.
    var colours: [String?] { palette.map(\.colour) }

    static func == (a: XpmBlock, b: XpmBlock) -> Bool {
        a.width == b.width && a.height == b.height
            && a.declaredColours == b.declaredColours && a.charsPerPixel == b.charsPerPixel
            && a.rows == b.rows
            && a.palette.map(\.key) == b.palette.map(\.key)
            && a.palette.map(\.colour) == b.palette.map(\.colour)
    }

    /// The colour covering most of the picture, transparency not counted. Falls back to the
    /// first opaque palette entry when there are no pixels.
    var dominantColour: String? {
        guard let grid = pixels() else { return colours.compactMap { $0 }.first }
        var tally: [String: Int] = [:]
        for row in grid {
            for pixel in row {
                guard let pixel else { continue }
                tally[pixel, default: 0] += 1
            }
        }
        // Ties broken by the colour value, so the result is stable across runs.
        return tally.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// The same block with one palette entry given a different colour. The key is kept, so
    /// every pixel referencing it takes the new colour. Out-of-range indices return `self`.
    func replacingColour(at index: Int, with colour: String?) -> XpmBlock {
        guard palette.indices.contains(index) else { return self }
        var updated = palette
        updated[index] = (key: palette[index].key, colour: colour)
        return XpmBlock(
            width: width,
            height: height,
            declaredColours: declaredColours,
            charsPerPixel: charsPerPixel,
            palette: updated,
            rows: rows
        )
    }

    /// The same picture with 1 more palette entry, which no pixel uses yet.
    func adding(_ entry: (key: String, colour: String?)) -> XpmBlock {
        XpmBlock(
            width: width,
            height: height,
            declaredColours: palette.count + 1,
            charsPerPixel: charsPerPixel,
            palette: palette + [entry],
            rows: rows
        )
    }

    /// The same picture on a different grid, cropped or padded, anchored top-left. Padding
    /// is transparent; a transparent palette entry is appended where padding needs one
    /// and the palette has none. Returned as it is where there is no key left for it.
    ///
    /// - Parameter clearAt: the clear entry to pad with, where not just any will do: one
    ///   clear at night as well.
    func resized(width newWidth: Int, height newHeight: Int, clearAt: Int? = nil) -> XpmBlock {
        // A picture of colours rather than keys, true colour, is not resized here.
        guard newWidth > 0, newHeight > 0, !palette.isEmpty else { return self }

        var palette = self.palette
        var clearIndex =
            clearAt.flatMap { palette.indices.contains($0) && palette[$0].colour == nil ? $0 : nil }
            ?? palette.firstIndex { $0.colour == nil }
        // A crop pads nothing, and a full palette does not stop it.
        let padding = newWidth > width || newHeight > height
        if clearIndex == nil, padding {
            // 256 entries at most, as 8 bits a pixel hold.
            guard palette.count < Self.mostColours else { return self }
            // A key as wide as the picture's; 1 slot past the palette's is free if any.
            let used = Set(palette.map(\.key))
            let width = max(1, charsPerPixel)
            let free = (0...palette.count).lazy.map { XpmBlock.key($0, width: width) }.first { !used.contains($0) }
            guard let free else { return self }
            palette.append((key: free, colour: nil))
            clearIndex = palette.count - 1
        }
        let clear = palette[clearIndex ?? 0].key

        let step = max(1, charsPerPixel)

        var out: [String] = []
        for y in 0..<newHeight {
            guard y < rows.count, y < height else {
                out.append(String(repeating: clear, count: newWidth))
                continue
            }
            let row = rows[y]
            var line = ""
            var index = row.startIndex
            var x = 0
            while x < newWidth {
                if x < width, index < row.endIndex {
                    let next =
                        row.index(index, offsetBy: step, limitedBy: row.endIndex)
                        ?? row.endIndex
                    line += String(row[index..<next])
                    index = next
                } else {
                    line += clear
                }
                x += 1
            }
            out.append(line)
        }

        return XpmBlock(
            width: newWidth,
            height: newHeight,
            declaredColours: palette.count,
            charsPerPixel: step,
            palette: palette,
            rows: out
        )
    }

    /// The most entries a palette takes: 8 bits a pixel.
    static let mostColours = 256

    /// Characters usable as palette keys, in a fixed order: every character except the
    /// double quote that ends the string. The fixed order makes resize, decompile and icon
    /// import reproducible, so a file can be diffed against its previous self.
    static let keyAlphabet = Array(
        "!#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_"
            + "abcdefghijklmnopqrstuvwxyz{|}~"
    )

    /// The key for palette slot `index`, `width` characters long: the slot written in
    /// the alphabet's digits, most significant first.
    static func key(_ index: Int, width: Int) -> String {
        let n = keyAlphabet.count
        var digits: [Character] = []
        var rest = index
        for _ in 0..<max(1, width) {
            digits.append(keyAlphabet[rest % n])
            rest /= n
        }
        return String(digits.reversed())
    }

    /// The picture as a grid of colours, nil where transparent.
    ///
    /// Returns nil for a solid block, which has no picture to resolve.
    func pixels() -> [[String?]]? {
        // A negative or absurd size is a malformed header: nothing to draw, not a trap.
        guard !isSolid, charsPerPixel > 0, width > 0, height > 0, width <= Self.mostPixels, height <= Self.mostPixels,
            width * height <= Self.mostPixels
        else { return nil }
        var lookup: [String: String?] = [:]
        for entry in palette { lookup[entry.key] = entry.colour }

        var grid: [[String?]] = []
        for row in rows.prefix(height) {
            var out: [String?] = []
            var index = row.startIndex
            while index < row.endIndex, out.count < width {
                let next =
                    row.index(index, offsetBy: charsPerPixel, limitedBy: row.endIndex)
                    ?? row.endIndex
                let key = String(row[index..<next])
                out.append(lookup[key] ?? nil)
                index = next
            }
            // A short row is padded rather than dropped, so a malformed file renders wrong
            // instead of trapping.
            while out.count < width { out.append(nil) }
            grid.append(out)
        }
        while grid.count < height { grid.append(Array(repeating: nil, count: width)) }
        return grid
    }
}

extension XpmBlock {
    /// No visible pixel: a pattern of nothing, or a night block that exists but is empty.
    var isBlank: Bool {
        guard let grid = pixels() else { return true }
        return !grid.contains { $0.contains { $0 != nil } }
    }
}
