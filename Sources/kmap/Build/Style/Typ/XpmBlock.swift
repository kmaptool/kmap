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

    /// Palette in declaration order. A nil colour is `none` — transparent, and drawn as
    /// whatever lies beneath.
    let palette: [(key: String, colour: String?)]

    /// The pixel rows, verbatim, `charsPerPixel` characters per pixel.
    let rows: [String]

    /// True when this carries colours only and no picture.
    var isSolid: Bool { width == 0 || height == 0 }

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
        return XpmBlock(width: width, height: height, declaredColours: declaredColours,
                        charsPerPixel: charsPerPixel, palette: updated, rows: rows)
    }

    /// The same picture on a different grid, cropped or padded, anchored top-left. Padding
    /// is transparent; a transparent palette entry is appended where the palette has none.
    func resized(width newWidth: Int, height newHeight: Int) -> XpmBlock {
        guard newWidth > 0, newHeight > 0 else { return self }

        var palette = self.palette
        var clearIndex = palette.firstIndex { $0.colour == nil }
        if clearIndex == nil {
            let used = Set(palette.map(\.key))
            let free = XpmBlock.keyAlphabet.map(String.init)
                .first { !used.contains($0) && $0.count == max(1, charsPerPixel) }
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
                    let next = row.index(index, offsetBy: step, limitedBy: row.endIndex)
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

        return XpmBlock(width: newWidth, height: newHeight, declaredColours: palette.count,
                        charsPerPixel: step, palette: palette, rows: out)
    }

    /// Characters usable as palette keys, in a fixed order: every character except the
    /// double quote that ends the string. The fixed order makes resize, decompile and icon
    /// import reproducible, so a file can be diffed against its previous self.
    static let keyAlphabet = Array(
        "!#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_"
        + "abcdefghijklmnopqrstuvwxyz{|}~")

    /// The key for palette slot `index`: one character where `width` is 1, otherwise the
    /// two-character form the TYP format allows.
    static func key(_ index: Int, width: Int) -> String {
        let n = keyAlphabet.count
        if width == 1 { return String(keyAlphabet[index % n]) }
        return String(keyAlphabet[(index / n) % n]) + String(keyAlphabet[index % n])
    }

    /// The picture as a grid of colours, nil where transparent.
    ///
    /// Returns nil for a solid block, which has no picture to resolve.
    func pixels() -> [[String?]]? {
        guard !isSolid, charsPerPixel > 0 else { return nil }
        var lookup: [String: String?] = [:]
        for entry in palette { lookup[entry.key] = entry.colour }

        var grid: [[String?]] = []
        for row in rows.prefix(height) {
            var out: [String?] = []
            var index = row.startIndex
            while index < row.endIndex, out.count < width {
                let next = row.index(index, offsetBy: charsPerPixel, limitedBy: row.endIndex)
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
