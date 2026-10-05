import Foundation

/// Reading a text TYP: the tolerant parser that keeps the file verbatim while
/// indexing its sections.
extension TypSource {
    static func read(_ url: URL) -> TypSource? {
        guard let text = text(of: url) else { return nil }
        return parse(text)
    }

    /// The line that tells mkgmap a text TYP is UTF-8, as kmap writes its own.
    static let codingLine = "; -*- coding: UTF-8 -*-"

    /// A text TYP's characters, read as mkgmap reads it: UTF-8 behind a byte-order mark or
    /// a coding line saying so; otherwise UTF-8 where the bytes are, and else the code
    /// page its CodePage line names, as TYPViewer saves.
    static func text(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeText([UInt8](data))
    }

    static func decodeText(_ bytes: [UInt8]) -> String {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        // A coding line in the first 2 lines decides, as it does for mkgmap.
        for line in Lines.of(CodePage.latin1(bytes.prefix(512))).prefix(2) {
            guard let named = codingName(in: line) else { continue }
            if named == "utf-8" || named == "utf8" { return String(decoding: bytes, as: UTF8.self) }
            let digits = named.filter(\.isNumber)
            if let page = Int(digits), named.hasPrefix("cp") || named.hasPrefix("windows") {
                return CodePage.decodeLenient(bytes, codePage: page)
            }
        }
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        let page = Lines.of(CodePage.latin1(bytes)).lazy.compactMap { line -> Int? in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "codepage" else {
                return nil
            }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first
        return CodePage.decodeLenient(bytes, codePage: page ?? CodePage.westernEuropean)
    }

    /// `declaringUTF8` where the text has anything past ASCII, which alone reads alike in
    /// every code page; ASCII text is left byte for byte.
    static func declaringUTF8IfNeeded(_ text: String) -> String {
        text.unicodeScalars.contains { !$0.isASCII } ? declaringUTF8(text) : text
    }

    /// The charset a `-*- coding: X -*-` line names, lower case; nil for any other line.
    private static func codingName(in line: String) -> String? {
        let lower = line.lowercased()
        guard lower.contains("-*-"), let at = lower.range(of: "coding:") else { return nil }
        let rest = lower[at.upperBound...].trimmingCharacters(in: .whitespaces)
        let word = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return word.isEmpty ? nil : word
    }

    /// `text` as written back in UTF-8: with the coding line first, so mkgmap reads it as
    /// UTF-8 and not by its CodePage line. A coding line naming another charset goes.
    static func declaringUTF8(_ text: String) -> String {
        func coding(_ line: String) -> Bool {
            let lower = line.lowercased()
            return lower.contains("-*-") && lower.contains("coding")
        }
        var lines = Lines.keepingTrailingBlank(text)
        let head = lines.prefix(2)
        if head.contains(where: { coding($0) && $0.lowercased().contains("utf-8") }) { return text }
        if let at = head.firstIndex(where: coding) { lines.remove(at: at) }
        return ([codingLine] + lines).joined(separator: text.contains("\r\n") ? "\r\n" : "\n")
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

            guard line.hasPrefix("[") else {
                pendingComments.removeAll()
                index += 1
                continue
            }
            let (end, next) = blockEnd(of: lines, from: index)
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
                let kind: MapElementKind =
                    line.lowercased() == "[_point]"
                    ? .point
                    : (line.lowercased() == "[_line]" ? .line : .polygon)
                if let section = parseSection(
                    kind: kind,
                    body: body,
                    lines: index..<next,
                    leadingComments: pendingComments
                ) {
                    sections.append(section)
                }
            default:
                break
            }

            pendingComments.removeAll()
            index = next
        }

        return TypSource(
            lines: lines,
            familyID: familyID,
            productID: productID,
            codePage: codePage,
            sections: sections,
            drawOrder: drawOrder,
            deliberatelyUnstyled: unstyled
        )
    }

    /// Parses `; kmap:unstyled lines 0x01 0x02 - why`; returns nil for any other comment.
    /// Text after the codes is ignored, and a malformed marker is treated as an ordinary
    /// comment rather than guessed at.
    private static func parseUnstyledMarker(
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
    private static func singular(_ word: String) -> String {
        word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    /// Where the block opening at `start` ends: the body runs up to `end`, and reading goes
    /// on at `next`. `[end]` is optional to mkgmap, which starts a new block at every
    /// header, so the next header or the end of the file closes one too.
    private static func blockEnd(of lines: [String], from start: Int) -> (end: Int, next: Int) {
        var i = start + 1
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.lowercased() == "[end]" { return (i, i + 1) }
            if line.hasPrefix("[") { return (i, i) }
            i += 1
        }
        return (lines.count, lines.count)
    }

    private static func parseSection(
        kind: MapElementKind,
        body: [String],
        lines: Range<Int>,
        leadingComments: [String]
    ) -> TypSection? {
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
        var sawSubtype = false

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
                sawSubtype = true
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

        guard var code else { return nil }
        // `Type=0x2f` names the point 0x2f00 to mkgmap, subtype 0, as everywhere in kmap.
        if kind == .point, !sawSubtype, code <= 0xFF { code <<= 8 }
        return TypSection(
            kind: kind,
            code: code,
            lines: lines,
            comments: comments,
            labels: labels,
            fontStyle: fontStyle,
            dayLabelColour: dayLabelColour,
            nightLabelColour: nightLabelColour,
            lineWidth: lineWidth,
            borderWidth: borderWidth,
            usesOrientation: usesOrientation,
            xpm: xpm,
            dayXpm: dayXpm,
            nightXpm: nightXpm
        )
    }

    /// Reads an Xpm header and the quoted lines under it. Returns the block and the index
    /// of the first line that is no longer part of it.
    private static func parseXpm(
        header: String,
        following body: [String],
        from start: Int
    ) -> (XpmBlock?, Int) {
        let numbers = unquote(header).split(separator: " ").map(String.init)
        guard numbers.count >= 4 else { return (nil, start) }
        // Some files write a line bitmap's height as a letter ("32 h 4 1"); an unreadable
        // number becomes zero rather than failing the whole section.
        let width = Int(numbers[0]) ?? 0
        let height = Int(numbers[1]) ?? 0
        let declared = Int(numbers[2]) ?? 0
        // One or two characters a pixel is what the format has; a wild number is a
        // typo, not an alphabet, and was an overflow further down.
        let perPixel = min(max(Int(numbers[3]) ?? 0, 0), 8)

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

        return (
            XpmBlock(
                width: width,
                height: height,
                declaredColours: declared,
                charsPerPixel: perPixel,
                palette: palette,
                rows: rows
            ), i
        )
    }

    /// Parses `"a c #F8FCF8"` or `". c none"`. The key is taken by width rather than by
    /// splitting: it is `keyLength` characters wide and may hold a space, a semicolon or a
    /// quote mark.
    private static func parsePaletteEntry(
        _ content: String,
        keyLength: Int
    ) -> (key: String, colour: String?)? {
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

    /// Parses `String=0x19,...`. The language index is hex; the text runs to end of line and
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
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ";" && !inQuotes {
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
