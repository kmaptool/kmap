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

/// Wraps text to `width` columns, honouring explicit newlines and breaking on spaces
/// where possible.
func wrapText(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [text] }
    var lines: [String] = []
    let normalized = text.replacingOccurrences(of: "\t", with: "    ")
    for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = String(rawLine)
        if line.isEmpty { lines.append(""); continue }
        while Text.cellWidth(line) > width {
            var head = Text.prefix(line, cells: width)
            // A column narrower than the first character still takes it, or nothing moves.
            if head.isEmpty { head = line[..<line.index(after: line.startIndex)] }
            let breakIdx = head.endIndex
            if let space = head.lastIndex(of: " "), space != line.startIndex {
                lines.append(String(line[line.startIndex..<space]))
                line = String(line[line.index(after: space)...])
            } else {
                lines.append(String(head))
                line = String(line[breakIdx...])
            }
        }
        // Empty only when a wide character took the whole of a narrow column above.
        if !line.isEmpty { lines.append(line) }
    }
    return lines
}

/// Strips ANSI/VT escape sequences and control characters from text produced by external
/// programs. Tabs and newlines are kept.
func stripControlSequences(_ text: String) -> String {
    let esc: UInt32 = 0x1B, bell: UInt32 = 0x07
    var result = ""
    result.reserveCapacity(text.count)
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let s = scalars[i]
        if s.value == esc {
            let next = i + 1 < scalars.count ? scalars[i + 1] : UnicodeScalar(0)
            if next == "[" {
                // A CSI sequence ends at its first final byte, 0x40...0x7E.
                i += 2
                while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                i += 1
            } else if next == "]" {
                // An OSC sequence ends at a bell or an ESC-backslash.
                i += 2
                while i < scalars.count, scalars[i].value != bell, scalars[i].value != esc { i += 1 }
                if i < scalars.count, scalars[i].value == esc { i += 1 }
                i += 1
            } else {
                i += 2
            }
            continue
        }
        if s == "\t" || s == "\n" || !Text.isControl(s) {
            result.unicodeScalars.append(s)
        }
        i += 1
    }
    return result
}

/// The string cut to `width` cells, the last one an ellipsis where anything was lost.
func truncate(_ s: String, to width: Int) -> String {
    guard width > 0 else { return "" }
    guard Text.cellWidth(s) > width else { return s }
    guard width > 1 else { return String(Text.prefix(s, cells: width)) }
    return String(Text.prefix(s, cells: width - 1)) + String(Glyph.ellipsis)
}
