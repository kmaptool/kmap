import Foundation

/// Text made to fit a cell grid: wrapped, cut short, and cleaned of what a terminal would
/// act on rather than show.
enum Text {
    /// Whether a scalar is a C0 or C1 control, or DEL.
    static func isControl(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
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
        while line.count > width {
            let breakIdx = line.index(line.startIndex, offsetBy: width)
            let head = line[line.startIndex..<breakIdx]
            if let space = head.lastIndex(of: " "), space != line.startIndex {
                lines.append(String(line[line.startIndex..<space]))
                line = String(line[line.index(after: space)...])
            } else {
                lines.append(String(head))
                line = String(line[breakIdx...])
            }
        }
        lines.append(line)
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
    guard s.count > width else { return s }
    guard width > 1 else { return String(s.prefix(width)) }
    return String(s.prefix(width - 1)) + String(Glyph.ellipsis)
}
