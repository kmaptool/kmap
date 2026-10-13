import Foundation

/// A TYP source's line syntax as mkgmap reads it: headers, `Key=Value` entries, numbers,
/// labels, comments and the markers kmap writes.
extension TypSource {
    /// Parses `; kmap:unstyled lines 0x01 0x02 - why`; returns nil for any other comment.
    /// Text after the codes is ignored, and a malformed marker is treated as an ordinary
    /// comment rather than guessed at.
    static func parseUnstyledMarker(
        _ line: String
    ) -> (kind: MapElementKind, codes: Set<Int>)? {
        let body = line.drop { $0 == ";" }.trimmingCharacters(in: .whitespaces)
        guard body.lowercased().hasPrefix("kmap:unstyled") else { return nil }

        let words = body.dropFirst("kmap:unstyled".count)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first,
            let kind = MapElementKind(rawValue: singular(first.lowercased()))
        else { return nil }

        var codes: Set<Int> = []
        for word in words.dropFirst() {
            guard let code = parseHex(word) else { break }
            codes.insert(code)
        }
        return codes.isEmpty ? nil : (kind, codes)
    }

    /// Drops a trailing `s`: the marker names its kind in the plural, `lines` not `line`.
    static func singular(_ word: String) -> String {
        word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    /// The body's end and where reading goes on: at `[end]`, the next header or the file's
    /// end, as in mkgmap; trailing blanks and comments go to the next block. `[_comments]`
    /// ends only at `[end]`.
    static func blockEnd(of lines: [String], from start: Int) -> (end: Int, next: Int) {
        let comments = header(of: lines[start]) == "[_comments]"
        var i = start + 1
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            // `[_comments]` ends at `[end]` itself: a symbol before it is comment text.
            if header(of: line) == "[end]", !comments || line.hasPrefix("[") { return (i, i + 1) }
            if passingSymbols(line).hasPrefix("["), !comments { break }
            i += 1
        }
        var close = i
        while close > start + 1 {
            let line = lines[close - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty || line.hasPrefix(";") else { break }
            close -= 1
        }
        return (close, close)
    }

    /// The header a line is, lower case; past the `]` mkgmap takes only spaces and a
    /// `;` comment.
    static func header(of line: String) -> String? {
        let trimmed = String(passingSymbols(line)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix(";") else { return nil }
        // mkgmap's scanner passes over spaces inside: `[ _polygon ]` is `[_polygon]`.
        return trimmed[...close].filter { !$0.isWhitespace }.lowercased()
    }

    /// `String=0x19,text` as mkgmap reads it: a number before the first comma is the
    /// language, and the text after it may hold commas. Without a number the whole value
    /// is a label in language 0.
    static func label(in value: String) -> (language: Int, text: String) {
        if let comma = value.firstIndex(of: ",") {
            let head = String(value[value.startIndex..<comma])
            if head == head.trimmingCharacters(in: .whitespaces), let language = decodedInteger(head) {
                return (language, String(value[value.index(after: comma)...]))
            }
        }
        return (0, value)
    }

    /// A `Key=Value` or `Key:Value` line as mkgmap reads it: the key without the spaces
    /// around it, and the value to the end of the line, a `;` in it too. Nil for any
    /// other line.
    static func entry(of line: String) -> (key: String, value: String)? {
        let start = passingSymbols(line)
        let key = start.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        let rest = start.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        // `:` too, which TYPViewer writes: `DaycustomColor:#4D80B3`.
        guard !key.isEmpty, rest.first == "=" || rest.first == ":" else { return nil }
        return (String(key), String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// A line past what mkgmap's reader passes over at its start: spaces, and any symbol
    /// but `;`, `[` and a quote. `#LineWidth=4` sets the width, `#[_line]` opens a section.
    static func passingSymbols(_ line: String) -> Substring {
        line.drop { $0.isWhitespace || !($0.isLetter || $0.isNumber || $0 == "_" || ";[\"".contains($0)) }
    }

    /// Whether `line` sets `key`, in any case and with spaces around the `=`.
    static func sets(_ key: String, _ line: String) -> Bool {
        entry(of: line)?.key.caseInsensitiveCompare(key) == .orderedSame
    }

    /// `Key=Value`, `String1=` read as `String=`: mkgmap takes any key that starts so as
    /// a label, and no other key with a number.
    static func keyValue(_ line: String) -> (String, String)? {
        guard let (key, value) = entry(of: line) else { return nil }
        if key.lowercased().hasPrefix("string") { return ("String", value) }
        return (key, value)
    }

    static func stripComment(_ text: String) -> String {
        var inQuotes = false
        for (offset, ch) in text.enumerated() {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ";" && !inQuotes {
                return String(text.prefix(offset))
            }
        }
        return text
    }

    static func unquote(_ text: String) -> String {
        guard text.hasPrefix("\""), text.count >= 2 else { return text }
        let body = text.dropFirst()
        guard let close = body.lastIndex(of: "\"") else { return String(body) }
        return String(body[body.startIndex..<close])
    }

    /// A number as mkgmap reads every number of a TYP, by `Integer.decode`: decimal, hex
    /// after `0x`, `0X` or `#`, octal after a leading 0, with a sign. `Type=47` is 0x2f.
    static func decodedInteger(_ text: String) -> Int? {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if let sign = t.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            t = t.dropFirst()
        }
        var radix = 10
        if t.hasPrefix("0x") || t.hasPrefix("0X") {
            radix = 16
            t = t.dropFirst(2)
        } else if t.hasPrefix("#") {
            radix = 16
            t = t.dropFirst()
        } else if t.hasPrefix("0"), t.count > 1 {
            radix = 8
            t = t.dropFirst()
        }
        // Digits alone: `Int` would take a second sign.
        guard let first = t.first, first != "-", first != "+", let value = Int(t, radix: radix) else { return nil }
        return negative ? -value : value
    }

    static func parseHex(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
        return Int(t, radix: 16)
    }

    /// The text between the first 2 quotes, or all of it where it has none.
    static func firstQuoted(_ text: String) -> String {
        guard let open = text.firstIndex(of: "\"") else { return text }
        let inside = text[text.index(after: open)...]
        return String(inside.prefix { $0 != "\"" })
    }

    /// Parses `Type=0x04b,0` entries: a code and its level, the level defaulting to 0.
    static func parseDrawOrder(_ body: [String]) -> [(code: Int, level: Int)] {
        var out: [(code: Int, level: Int)] = []
        for raw in body {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            guard let (key, value) = keyValue(line), key.uppercased() == "TYPE" else { continue }
            let parts = value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let first = parts.first, let code = decodedInteger(first) else { continue }
            let level = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            out.append((code, level))
        }
        return out
    }
}
