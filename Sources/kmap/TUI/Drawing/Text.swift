import Foundation

/// Text made to fit a cell grid: wrapped, cut short, and cleaned of what a terminal would
/// act on rather than show.
enum Text {
    /// Whether a scalar is a C0 or C1 control, or DEL.
    static func isControl(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
    }

    /// The columns a character takes on a terminal: two for the East Asian wide and
    /// fullwidth blocks and for emoji with a picture, none for a combining mark or a
    /// joiner, one for the rest. The interface is Latin and Cyrillic; this is for the
    /// data it shows, a style name or a line of mkgmap's output.
    /// Measured as the console will draw it: Windows is sent a narrow stand-in for some
    /// glyphs (a fullwidth plus becomes a plain one), and a wide measure there would
    /// leave a filler cell that puts the rest of the row a column out.
    static func cellWidth(_ ch: Character) -> Int {
        let ch = Glyph.drawable(ch)
        var width = 1
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if isZeroWidth(v) { if scalar == ch.unicodeScalars.first { width = 0 }; continue }
            if isWide(v) { return 2 }
        }
        return width
    }

    /// The columns a string takes.
    static func cellWidth(_ s: String) -> Int {
        s.reduce(0) { $0 + cellWidth($1) }
    }

    /// The longest prefix that fits `cells` columns.
    static func prefix(_ s: String, cells: Int) -> Substring {
        var used = 0
        var end = s.startIndex
        for (index, ch) in zip(s.indices, s) {
            let w = cellWidth(ch)
            if used + w > cells { break }
            used += w
            end = s.index(after: index)
        }
        return s[s.startIndex..<end]
    }

    private static func isZeroWidth(_ v: UInt32) -> Bool {
        (0x0300...0x036F).contains(v) || (0x1AB0...0x1AFF).contains(v) || (0x1DC0...0x1DFF).contains(v)
            || (0x20D0...0x20FF).contains(v) || (0xFE00...0xFE0F).contains(v) || (0xFE20...0xFE2F).contains(v)
            || v == 0x200B || v == 0x200C || v == 0x200D || v == 0x2060 || (0xE0100...0xE01EF).contains(v)
    }

    private static func isWide(_ v: UInt32) -> Bool {
        (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) || (0x3041...0x33FF).contains(v)
            || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v)
            || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v)
            || (0x1F300...0x1F64F).contains(v) || (0x1F680...0x1F6FF).contains(v) || (0x1F900...0x1F9FF).contains(v)
            || (0x1FA70...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
    }
}
