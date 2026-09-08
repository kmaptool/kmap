import Foundation

/// Reading a text TYP: the tolerant parser that keeps the file verbatim while
/// indexing its sections.
extension TypSource {
    static func read(_ url: URL) -> TypSource? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> TypSource {
        // `Lines` rather than `components(separatedBy:)`: Swift treats "\r\n" as one
        // Character, so the obvious splits disagree across platforms. The trailing blank is
        // kept so a file ending in a newline still ends in one after a round trip.
        let lines = Lines.keepingTrailingBlank(text)

        var familyID: Int?
        var productID: Int?
        var codePage: Int?
        var sections: [TypSection] = []
        var drawOrder: [(code: Int, level: Int)] = []
        var unstyled: [MapElementKind: Set<Int>] = [:]

        var index = 0
        /// Comments above a section header belong to it.
        var pendingComments: [String] = []

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)

            if line.isEmpty { pendingComments.removeAll(); index += 1; continue }
            if line.hasPrefix(";") {
                if let marker = parseUnstyledMarker(line) {
                    unstyled[marker.kind, default: []].formUnion(marker.codes)
                }
                pendingComments.append(line)
                index += 1
                continue
            }

            guard line.hasPrefix("["), let end = blockEnd(of: lines, from: index) else {
                pendingComments.removeAll()
                index += 1
                continue
            }
            let body = Array(lines[(index + 1)..<end])

            switch line.lowercased() {
            case "[_id]":
                for entry in body {
                    guard let (key, value) = keyValue(entry) else { continue }
                    switch key.uppercased() {
                    case "FID": familyID = Int(value)
                    case "PRODUCTCODE": productID = Int(value)
                    case "CODEPAGE": codePage = Int(value)
                    default: break
                    }
                }
            case "[_draworder]":
                drawOrder = parseDrawOrder(body)
            case "[_point]", "[_line]", "[_polygon]":
                let kind: MapElementKind = line.lowercased() == "[_point]" ? .point
                    : (line.lowercased() == "[_line]" ? .line : .polygon)
                if let section = parseSection(kind: kind, body: body,
                                              lines: index..<(end + 1),
                                              leadingComments: pendingComments) {
                    sections.append(section)
                }
            default:
                break
            }

            pendingComments.removeAll()
            index = end + 1
        }

        return TypSource(lines: lines, familyID: familyID, productID: productID,
                         codePage: codePage, sections: sections, drawOrder: drawOrder,
                         deliberatelyUnstyled: unstyled)
    }

    /// Parses `; kmap:unstyled lines 0x01 0x02 — why`; returns nil for any other comment.
    /// Text after the codes is ignored, and a malformed marker is treated as an ordinary
    /// comment rather than guessed at.
    private static func parseUnstyledMarker(_ line: String)
        -> (kind: MapElementKind, codes: Set<Int>)? {
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
    private static func singular(_ word: String) -> String {
        word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    /// Index of the `[end]` closing the block that opens at `start`.
    private static func blockEnd(of lines: [String], from start: Int) -> Int? {
        var i = start + 1
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).lowercased() == "[end]" { return i }
            i += 1
        }
        return nil
    }

    private static func parseSection(kind: MapElementKind, body: [String],
                                     lines: Range<Int>,
                                     leadingComments: [String]) -> TypSection? {
        var code: Int?
        var comments = leadingComments
        var labels: [(language: Int, text: String)] = []
        var fontStyle: String?
        var dayLabelColour: String?
        var nightLabelColour: String?
        var lineWidth: Int?
        var borderWidth: Int?
        var usesOrientation = false
        var xpm: XpmBlock?
        var dayXpm: XpmBlock?
        var nightXpm: XpmBlock?

        var i = 0
        while i < body.count {
            let raw = body[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }
            if line.hasPrefix(";") { comments.append(line); i += 1; continue }

            guard let (key, value) = keyValue(line) else { i += 1; continue }

            switch key.uppercased() {
            case "TYPE":
                code = parseHex(value)
            case "SUBTYPE":
                // Points fold the subtype into the code; where a file spells it out
                // separately, the two combine as `(type << 8) | subtype`.
                if let sub = parseHex(value), let base = code { code = (base << 8) | sub }
            case "STRING":
                if let label = parseLabel(value) { labels.append(label) }
            case "FONTSTYLE":
                fontStyle = value
            case "DAYCUSTOMCOLOR":
                dayLabelColour = value
            case "NIGHTCUSTOMCOLOR":
                nightLabelColour = value
            case "LINEWIDTH":
                lineWidth = Int(value)
            case "BORDERWIDTH":
                borderWidth = Int(value)
            case "USEORIENTATION":
                usesOrientation = value.uppercased().hasPrefix("Y")
            case "XPM", "DAYXPM", "NIGHTXPM":
                let (block, consumed) = parseXpm(header: value, following: body, from: i + 1)
                switch key.uppercased() {
                case "XPM": xpm = block
                case "DAYXPM": dayXpm = block
                default: nightXpm = block
                }
                i = consumed - 1
            default:
                break
            }
            i += 1
        }

        guard let code else { return nil }
        return TypSection(kind: kind, code: code, lines: lines, comments: comments,
                          labels: labels, fontStyle: fontStyle,
                          dayLabelColour: dayLabelColour, nightLabelColour: nightLabelColour,
                          lineWidth: lineWidth, borderWidth: borderWidth,
                          usesOrientation: usesOrientation,
                          xpm: xpm, dayXpm: dayXpm, nightXpm: nightXpm)
    }

    /// Reads an Xpm header and the quoted lines under it. Returns the block and the index
    /// of the first line that is no longer part of it.
    private static func parseXpm(header: String, following body: [String],
                                 from start: Int) -> (XpmBlock?, Int) {
        let numbers = unquote(header).split(separator: " ").map(String.init)
        guard numbers.count >= 4 else { return (nil, start) }
        // Some files write a line bitmap's height as a letter ("32 h 4 1"); an unreadable
        // number becomes zero rather than failing the whole section.
        let width = Int(numbers[0]) ?? 0
        let height = Int(numbers[1]) ?? 0
        let declared = Int(numbers[2]) ?? 0
        let perPixel = Int(numbers[3]) ?? 0

        var palette: [(key: String, colour: String?)] = []
        var rows: [String] = []
        var i = start

        while i < body.count {
            let line = body[i].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\"") else { break }
            let content = unquote(line)
            if palette.count < declared, let entry = parsePaletteEntry(content, keyLength: perPixel) {
                palette.append(entry)
            } else {
                rows.append(content)
            }
            i += 1
        }

        return (XpmBlock(width: width, height: height, declaredColours: declared,
                         charsPerPixel: perPixel, palette: palette, rows: rows), i)
    }

    /// Parses `"a c #F8FCF8"` or `". c none"`. The key is taken by width rather than by
    /// splitting: it is `keyLength` characters wide and may hold a space, a semicolon or a
    /// quote mark.
    private static func parsePaletteEntry(_ content: String,
                                          keyLength: Int) -> (key: String, colour: String?)? {
        let width = max(1, keyLength)
        guard content.count >= width + 2 else { return nil }
        let key = String(content.prefix(width))
        let rest = content.dropFirst(width).trimmingCharacters(in: .whitespaces)
        guard rest.lowercased().hasPrefix("c ") else { return nil }
        let value = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if value.lowercased() == "none" { return (key, nil) }
        guard value.hasPrefix("#") else { return nil }
        return (key, value.uppercased())
    }

    /// Parses `Type=0x04b,0` entries: a code and its level, the level defaulting to 0.
    private static func parseDrawOrder(_ body: [String]) -> [(code: Int, level: Int)] {
        var out: [(code: Int, level: Int)] = []
        for raw in body {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            guard let (key, value) = keyValue(line), key.uppercased() == "TYPE" else { continue }
            let parts = value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let first = parts.first, let code = parseHex(first) else { continue }
            let level = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            out.append((code, level))
        }
        return out
    }

    /// Parses `String=0x19,…`. The language index is hex; the text runs to end of line and
    /// may itself contain commas.
    private static func parseLabel(_ value: String) -> (language: Int, text: String)? {
        guard let comma = value.firstIndex(of: ",") else { return nil }
        guard let language = parseHex(String(value[value.startIndex..<comma])) else { return nil }
        return (language, String(value[value.index(after: comma)...]))
    }

    // MARK: Small parsing helpers

    /// Splits `Key=Value`, dropping any trailing comment. A comment starts at a `;` outside
    /// quotes; a semicolon is also a legal palette key, so quoting must be tracked.
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        // A key is letters plus an optional trailing number, as in `String1=`. The number is
        // the language ordinal, not part of the key, so the stem is returned.
        let stem = String(key.reversed().drop(while: \.isNumber).reversed())
        guard !stem.isEmpty, stem.allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        let value = stripComment(String(line[line.index(after: eq)...]))
            .trimmingCharacters(in: .whitespaces)
        return (stem, value)
    }

    private static func stripComment(_ text: String) -> String {
        var inQuotes = false
        for (offset, ch) in text.enumerated() {
            if ch == "\"" { inQuotes.toggle() }
            else if ch == ";" && !inQuotes {
                return String(text.prefix(offset))
            }
        }
        return text
    }

    private static func unquote(_ text: String) -> String {
        guard text.hasPrefix("\""), text.count >= 2 else { return text }
        let body = text.dropFirst()
        guard let close = body.lastIndex(of: "\"") else { return String(body) }
        return String(body[body.startIndex..<close])
    }

    private static func parseHex(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
        return Int(t, radix: 16)
    }
}
