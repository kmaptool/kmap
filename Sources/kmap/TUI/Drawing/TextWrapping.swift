import Foundation

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
