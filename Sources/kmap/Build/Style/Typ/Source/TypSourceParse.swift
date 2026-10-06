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
        // A TYP source is kilobytes; a file of gigabytes named like 1 is not read whole.
        guard FileTools.size(of: url) <= 64 << 20, let data = try? Data(contentsOf: url) else { return nil }
        return decodeText([UInt8](data))
    }

    static func decodeText(_ bytes: [UInt8]) -> String { decoding(bytes).text }

    /// The characters, and whether they are the bytes one for one: past ASCII, in a page
    /// or charset kmap has no table for.
    static func decoding(_ bytes: [UInt8]) -> (text: String, byteForByte: Bool) {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (String(decoding: bytes.dropFirst(3), as: UTF8.self), false)
        }
        let past = bytes.contains { $0 >= 0x80 }
        // A coding line in lines 1 and 2 decides, as for mkgmap, read whole however long.
        var head = 0
        var ends = 0
        while head < bytes.count, ends < 2 {
            if bytes[head] == 0x0A { ends += 1 }
            head += 1
        }
        for line in TextLines.of(CodePage.latin1(bytes.prefix(head))).prefix(2) {
            // Read by the name as meant: `utf-8;` or `utf-8-unix` is UTF-8. kmap's copy mends
            // the line where mkgmap's probe would not take it.
            guard let raw = codingName(in: line) else { continue }
            let named = cleanCharset(raw)
            if named.isEmpty { continue }
            // A name mkgmap would refuse over bytes that are UTF-8 is a slip of the label: the
            // text is UTF-8, and kmap's copy says so.
            if !javaReadsCharset(raw), !javaReadsCharset(named), past, let text = String(bytes: bytes, encoding: .utf8)
            {
                return (text, false)
            }
            if named == "utf-8" || named == "utf8" { return (String(decoding: bytes, as: UTF8.self), false) }
            if named == "iso-8859-1" { return (CodePage.latin1(bytes), false) }
            let digits = named.filter(\.isNumber)
            if let page = Int(digits), named.hasPrefix("cp") || named.hasPrefix("windows") {
                if page == CodePage.utf8 { return (String(decoding: bytes, as: UTF8.self), false) }
                return (CodePage.decodeLenient(bytes, codePage: page), past && !CodePage.supported.contains(page))
            }
            // A charset named otherwise, KOI8-R say, is mkgmap's to read and kmap's to keep.
            return (CodePage.latin1(bytes), past)
        }
        if let text = String(bytes: bytes, encoding: .utf8) { return (text, false) }
        let named = TextLines.of(CodePage.latin1(bytes)).lazy.compactMap { line -> Int? in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "codepage" else {
                return nil
            }
            return probedPage(stripComment(String(parts[1])))
        }.first
        let page = named ?? CodePage.westernEuropean
        return (CodePage.decodeLenient(bytes, codePage: page), past && !CodePage.supported.contains(page))
    }

    /// Whether labels in this code page are kept byte for byte: kmap has no table for it.
    static func keptByteForByte(codePage: Int?) -> Bool {
        // 0 is mkgmap's own default, not a page: such labels are ASCII.
        guard let codePage, codePage != 0 else { return false }
        return codePage != CodePage.utf8 && !CodePage.supported.contains(codePage)
    }

    /// The bytes of a TYP source kmap wrote from a compiled one in `codePage`: its labels
    /// went in byte for byte where kmap cannot read the page, and go out the same way.
    static func bytesOfWritten(_ text: String, codePage: Int?) -> Data {
        bytesToWrite(text, declaring: true, byteForByte: keptByteForByte(codePage: codePage))
    }

    /// `declaringUTF8` where the text has anything past ASCII, which alone reads alike in
    /// every code page; ASCII text is left byte for byte.
    static func declaringUTF8IfNeeded(_ text: String) -> String {
        text.unicodeScalars.contains { !$0.isASCII } ? declaringUTF8(text) : text
    }

    /// The bytes a TYP source is written as: UTF-8 saying so where past ASCII (always, with
    /// `declaring`); a text read byte for byte goes back so, anything past a byte as `?`.
    static func bytesToWrite(_ text: String, declaring: Bool = false, byteForByte: Bool = false) -> Data {
        if byteForByte {
            return Data(text.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : UInt8(ascii: "?") })
        }
        return Data((declaring ? declaringUTF8(text) : declaringUTF8IfNeeded(text)).utf8)
    }

    /// Whether mkgmap's charset probe fails on `text`: failing a coding line in the first 2
    /// lines it takes the first `CodePage=` line for a charset, and a note behind the number,
    /// or a page of 0, names none Java has. kmap's own copy then says UTF-8 first.
    static func codePageTripsMkgmap(_ text: String) -> Bool {
        for (number, line) in TextLines.of(text).enumerated() {
            if number < 2, let name = codingName(in: line) { return !javaReadsCharset(name) }
            guard line.hasPrefix("CodePage=") else { continue }
            guard let page = probedPage(String(line.dropFirst("CodePage=".count))) else { return true }
            return !javaPages.contains(page)
        }
        return false
    }

    /// The page mkgmap's probe asks Java for: a number, as `cpN`, or a `cpN` name as it is.
    private static func probedPage(_ value: String) -> Int? {
        let plain = value.trimmingCharacters(in: .whitespaces)
        if let page = decodedInteger(plain) { return page }
        // As Java names it: digits alone, no sign or leading 0, and 65001 is no `cp` name.
        let digits = plain.dropFirst(2)
        guard plain.lowercased().hasPrefix("cp"), let first = digits.first, first != "0",
            digits.allSatisfy({ $0.isASCII && $0.isNumber }), let page = Int(digits), page != CodePage.utf8
        else { return nil }
        return page
    }

    /// Pages any Java reads as `cpN`, which is how mkgmap asks for them. Another may read
    /// too: it costs only a copy that says UTF-8.
    private static let javaPages = Set(
        [437, 737, 775, 850, 852, 855, 857, 858, 862, 866, 874, 65001] + Array(1250...1258)
    )

    /// `text` with its first `CodePage=` line as a plain number, its note gone, or without
    /// it where none is read: a copy kept byte for byte has no coding line to stop mkgmap's
    /// probe before it.
    static func plainCodePageLine(_ text: String) -> String {
        var lines = TextLines.keepingTrailingBlank(text)
        guard let at = lines.firstIndex(where: { $0.hasPrefix("CodePage=") }) else { return text }
        if let page = decodedInteger(stripComment(String(lines[at].dropFirst("CodePage=".count)))), page > 0 {
            lines[at] = "CodePage=\(page)"
        } else {
            lines.remove(at: at)
        }
        return lines.joined(separator: "\n")
    }

    /// The charset a `-*- coding: X -*-` line names, lower case; nil for any other line.
    private static func codingName(in line: String) -> String? {
        // Spelt as mkgmap's probe looks for it, case and all; the charset runs to a space,
        // and may be empty.
        guard let at = line.range(of: "-*- coding:") else { return nil }
        // Java's trim, both ends: control characters and the space, no other blank.
        func blank(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { $0.value <= 0x20 } }
        var rest = line[at.upperBound...].drop(while: blank)
        while let last = rest.last, blank(last) { rest = rest.dropLast() }
        return String(rest.prefix { $0 != " " }).lowercased()
    }

    /// A coding name as a reader means it: cut at the first character no charset name has,
    /// Emacs's line-end endings dropped and its own spellings put right.
    static func cleanCharset(_ raw: String) -> String {
        var name = String(raw.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "+.:_-".contains($0)) })
        for ending in ["-unix", "-dos", "-mac"] where name.hasSuffix(ending) { name.removeLast(ending.count) }
        guard let first = name.first, first.isLetter || first.isNumber else { return "" }
        // `iso8859-16` and `iso8859_10` as `iso-8859-16`, Java's own dashed spelling.
        for spelling in ["iso8859-", "iso8859_"] where name.hasPrefix(spelling) {
            name = "iso-8859-" + name.dropFirst(spelling.count)
        }
        return emacsNames[name] ?? name
    }

    /// Emacs's own spellings, as Java names them. `cyrillic-alternativnyj` differs from
    /// cp866 in a few signs past the letters, which no Java charset has.
    private static let emacsNames = [
        "latin-0": "iso-8859-15", "latin-1": "iso-8859-1", "iso-latin-1": "iso-8859-1", "latin-2": "iso-8859-2",
        "iso-latin-2": "iso-8859-2", "latin-3": "iso-8859-3", "iso-latin-3": "iso-8859-3", "latin-4": "iso-8859-4",
        "iso-latin-4": "iso-8859-4", "latin-5": "iso-8859-9", "iso-latin-5": "iso-8859-9", "latin-7": "iso-8859-13",
        "iso-latin-7": "iso-8859-13", "iso-latin-9": "iso-8859-15",
        "latin-10": "iso-8859-16", "iso-latin-10": "iso-8859-16", "cyrillic-iso-8bit": "iso-8859-5",
        "cyrillic-koi8": "koi8-r", "cp878": "koi8-r", "cyrillic-alternativnyj": "cp866", "alternativnyj": "cp866",
        "greek-iso-8bit": "iso-8859-7", "hebrew-iso-8bit": "iso-8859-8", "iso-8859-8-i": "iso-8859-8",
        "iso-8859-8-e": "iso-8859-8", "utf-8-with-signature": "utf-8", "mule-utf-8": "utf-8"
    ]

    /// `text` with its first coding line as mkgmap's probe can take it: the cleaned name,
    /// or none where even that is no charset Java reads. A copy kept byte for byte says
    /// no UTF-8 of its own, so the line must read.
    static func mendedCodingLine(_ text: String) -> String {
        var lines = TextLines.keepingTrailingBlank(text)
        guard let at = lines.prefix(2).firstIndex(where: { codingName(in: $0) != nil }),
            let raw = codingName(in: lines[at]), !javaReadsCharset(raw)
        else { return text }
        let clean = cleanCharset(raw)
        if !clean.isEmpty, javaReadsCharset(clean) {
            lines[at] = "; -*- coding: \(clean) -*-"
        } else {
            lines.remove(at: at)
        }
        return lines.joined(separator: "\n")
    }

    /// Whether Java takes `name` as a charset: a legal name, and none of those known not
    /// to be one. Another legal name is let pass, as it would pass in the original.
    private static func javaReadsCharset(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII,
            first.properties.isAlphabetic || ("0"..."9").contains(first)
        else { return false }
        let legal = name.unicodeScalars.allSatisfy {
            $0.isASCII
                && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "-+.:_".unicodeScalars.contains($0))
        }
        let unknown: Set<String> = [
            "cp65001", "windows-65001", "iso-8859-10", "iso-8859-12", "iso-8859-14", "iso8859-10", "iso8859-11",
            "iso8859-12", "iso8859-14", "iso8859-16", "iso8859_10", "iso8859_12", "iso8859_14"
        ]
        return legal && emacsNames[name] == nil && !unknown.contains(name)
            && !["-unix", "-dos", "-mac"].contains(where: name.hasSuffix)
    }

    /// `text` as written back in UTF-8: with the coding line first, so mkgmap reads it as
    /// UTF-8 and not by its CodePage line. A coding line naming another charset goes.
    static func declaringUTF8(_ text: String) -> String {
        func coding(_ line: String) -> Bool {
            let lower = line.lowercased()
            return lower.contains("-*-") && lower.contains("coding")
        }
        var lines = TextLines.keepingTrailingBlank(text)
        let head = lines.prefix(2)
        // The first coding line is the one mkgmap takes.
        if let first = head.lazy.compactMap(codingName).first, ["utf-8", "utf8"].contains(first) { return text }
        if let at = head.firstIndex(where: coding) { lines.remove(at: at) }
        return ([codingLine] + lines).joined(separator: text.contains("\r\n") ? "\r\n" : "\n")
    }

    static func parse(_ text: String) -> TypSource {
        // `Lines` rather than `components(separatedBy:)`: Swift treats "\r\n" as one
        // Character, so the obvious splits disagree across platforms. The trailing blank is
        // kept so a file ending in a newline still ends in one after a round trip.
        let lines = TextLines.keepingTrailingBlank(text)

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

            guard passingSymbols(line).hasPrefix("[") else {
                pendingComments.removeAll()
                index += 1
                continue
            }
            let (end, next) = blockEnd(of: lines, from: index)
            let body = Array(lines[(index + 1)..<end])
            let header = Self.header(of: line) ?? line.lowercased()

            switch header {
            case "[_id]":
                // A note behind a number is let pass here, as `TypInfo` lets it.
                for entry in body {
                    guard let (key, noted) = keyValue(entry) else { continue }
                    let value = stripComment(noted)
                    switch key.uppercased() {
                    case "FID": familyID = decodedInteger(value)
                    case "PRODUCTCODE": productID = decodedInteger(value)
                    case "CODEPAGE": codePage = decodedInteger(value)
                    default: break
                    }
                }
            case "[_draworder]":
                drawOrder = parseDrawOrder(body)
            case "[_point]", "[_line]", "[_polygon]":
                let kind: MapElementKind =
                    header == "[_point]"
                    ? .point
                    : (header == "[_line]" ? .line : .polygon)
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

    private static func parseSection(
        kind: MapElementKind,
        body: [String],
        lines: Range<Int>,
        leadingComments: [String]
    ) -> TypSection? {
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
        // Any kind as mkgmap reads it: `Type=` sets the type, and the subtype too from a
        // number of 0x100 or more; `SubType=` sets the subtype; the later line wins.
        var pointType: Int?
        var pointSubtype = 0
        var hasSubtype = false

        var i = 0
        while i < body.count {
            let raw = body[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }
            if line.hasPrefix(";") { comments.append(line); i += 1; continue }

            guard let (key, value) = keyValue(line) else { i += 1; continue }

            switch key.uppercased() {
            case "TYPE":
                if let number = decodedInteger(value) {
                    pointType = number >= 0x100 ? number >> 8 : number & 0xFF
                    if number >= 0x100 {
                        pointSubtype = number & 0xFF
                        hasSubtype = true
                    }
                }
            case "SUBTYPE":
                if let number = decodedInteger(value) {
                    pointSubtype = number & 0xFF
                    hasSubtype = true
                }
            case "STRING":
                labels.append(label(in: value))
            case "FONTSTYLE":
                fontStyle = value
            case "DAYCUSTOMCOLOR":
                dayLabelColour = value
            case "NIGHTCUSTOMCOLOR":
                nightLabelColour = value
            case "LINEWIDTH":
                lineWidth = decodedInteger(value)
            case "BORDERWIDTH":
                borderWidth = decodedInteger(value)
            case "USEORIENTATION":
                usesOrientation = value.hasPrefix("Y")
            case "XPM", "DAYXPM", "NIGHTXPM":
                let (block, consumed) = parseXpm(header: value, following: body, from: i + 1)
                // mkgmap takes a point's `Xpm=` and `DayXpm=` alike, the later winning.
                switch key.uppercased() {
                case "XPM":
                    xpm = block
                    if kind == .point { dayXpm = nil }
                // A line or polygon has 1 picture: mkgmap passes over the others.
                case "DAYXPM" where kind == .point:
                    dayXpm = block
                    xpm = nil
                case "NIGHTXPM" where kind == .point:
                    nightXpm = block
                default: break
                }
                i = consumed - 1
            default:
                break
            }
            i += 1
        }

        guard let pointType else { return nil }
        // `Type=0x2f` names the point 0x2f00 to mkgmap, subtype 0, as everywhere in kmap; a
        // line or polygon is its type alone, or `(type << 8) | subtype` where it has one.
        let code = kind == .point || hasSubtype ? (pointType << 8) | pointSubtype : pointType
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
        // Between the first 2 quotes, as mkgmap reads it: a note after may hold quotes too.
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let numbers = (trimmed.hasPrefix("\"") ? firstQuoted(trimmed) : trimmed)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
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
            // A blank line is the picture's where a quoted one follows, as `TypEdit.pictureEnd`
            // takes it: mkgmap reads a palette or true colour past it, and a re-render drops it.
            if line.isEmpty {
                let next = body[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard next?.trimmingCharacters(in: .whitespaces).hasPrefix("\"") == true else { break }
                i += 1
                continue
            }
            guard line.hasPrefix("\"") else { break }
            if palette.count < declared, let entry = parsePaletteEntry(line, keyLength: perPixel) {
                palette.append(entry)
            } else {
                // A row is as wide as the picture, as mkgmap takes it, whatever follows; a
                // true-colour row names its colours and is read whole.
                let inside = line.dropFirst()
                // A wild width is a typo: its product with the key width would overflow.
                let (wide, overflowed) = width.multipliedReportingOverflow(by: max(1, perPixel))
                rows.append(
                    declared > 0 && !overflowed && wide > 0 && inside.count >= wide
                        ? String(inside.prefix(wide)) : unquote(line)
                )
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

    /// Parses `"a c #F8FCF8"` or `". c none"`, and any `alpha=` after it. The key is taken by
    /// width, `keyLength` characters that may hold a space, a semicolon or a quote mark; the
    /// colour is the word after `c`, as mkgmap reads it.
    private static func parsePaletteEntry(
        _ line: String,
        keyLength: Int
    ) -> (key: String, colour: String?)? {
        let width = max(1, keyLength)
        let inside = line.dropFirst()
        guard inside.count >= width + 2 else { return nil }
        let key = String(inside.prefix(width))
        func blank(_ c: Character) -> Bool { c == " " || c == "\t" }
        // `c` as a word of its own, then the colour: `#` and its digits, a space between
        // them or not, or `none`.
        let rest = inside.dropFirst(width).drop(while: blank)
        guard rest.first == "c", let next = rest.dropFirst().first, blank(next) || next == "#" else { return nil }
        let value = rest.dropFirst().drop(while: blank)
        let hash = value.first == "#"
        let digits = hash ? value.dropFirst().drop(while: blank) : value
        let word = digits.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        let after = digits.dropFirst(word.count).drop(while: blank)
        guard after.first == "\"" else { return nil }
        let tail = String(after.dropFirst())
        if !hash, word.lowercased() == "none" { return (key, withAlpha(alpha(in: tail), on: nil)) }
        guard hash, !word.isEmpty else { return nil }
        // A colour that will not read stays a palette entry as written, alpha or not, so an
        // edit keeps it and the screen can show it is wrong.
        // 6 hex digits, or 8 and more of which mkgmap reads the first 8, whatever follows.
        let hex = word.count == 6 ? word[...] : word.prefix(8)
        guard word.count == 6 || word.count >= 8, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return (key, "#" + word.uppercased())
        }
        let read = word.count > 8 ? word.prefix(8) : word[...]
        return (key, withAlpha(alpha(in: tail), on: "#" + read.uppercased()))
    }

    /// Whether `line` reads as a palette entry, as the parse takes it; a line that does not
    /// counts as a row.
    static func isPaletteEntry(_ line: String, keyLength: Int) -> Bool {
        parsePaletteEntry(line.trimmingCharacters(in: .whitespaces), keyLength: keyLength) != nil
    }

    /// The last `<word>alpha=N` after a palette line's closing quote, as mkgmap reads it: a
    /// word ending in `alpha`, TYPViewer's `canalalpha` too, then `=` and a number.
    private static func alpha(in tail: String) -> Int? {
        let tokens = tail.split(whereSeparator: { $0 == " " || $0 == "\t" }).flatMap { word -> [Substring] in
            // `=` stands alone, as mkgmap's scanner takes it.
            var out: [Substring] = []
            var rest = word[...]
            while let eq = rest.firstIndex(of: "=") {
                if eq > rest.startIndex { out.append(rest[rest.startIndex..<eq]) }
                out.append(rest[eq...eq])
                rest = rest[rest.index(after: eq)...]
            }
            if !rest.isEmpty { out.append(rest) }
            return out
        }
        var found: Int?
        var at = 0
        while at + 2 < tokens.count {
            if tokens[at].hasSuffix("alpha"), tokens[at + 1] == "=" {
                let number = tokens[at + 2].prefix { $0.isLetter || $0.isNumber }
                if let level = decodedInteger(String(number)) { found = level }
                at += 3
            } else {
                at += 1
            }
        }
        return found
    }

    /// A palette colour as mkgmap holds it, with `alpha` (0 opaque up to 15 clear) laid on:
    /// `#RRGGBBAA`, its alpha left out where whole, and none where nothing shows. An alpha
    /// on `none` colours it black, as in mkgmap.
    static func withAlpha(_ alpha: Int?, on colour: String?) -> String? {
        var hex = colour.map { String($0.dropFirst()) } ?? "00000000"
        // Wrapping, as mkgmap's ints do: only the low 8 bits are kept, and a wild alpha in
        // a damaged file must not trap.
        if let alpha { hex = String(hex.prefix(6)) + String(format: "%02X", (255 &- ((alpha &<< 4) &+ alpha)) & 0xFF) }
        guard hex.count == 8 else { return colour }
        switch hex.suffix(2) {
        case "00": return nil
        case "FF": return "#" + hex.prefix(6)
        default: return "#" + hex
        }
    }

    /// The text between the first 2 quotes, or all of it where it has none.
    private static func firstQuoted(_ text: String) -> String {
        guard let open = text.firstIndex(of: "\"") else { return text }
        let inside = text[text.index(after: open)...]
        return String(inside.prefix { $0 != "\"" })
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
            guard let first = parts.first, let code = decodedInteger(first) else { continue }
            let level = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            out.append((code, level))
        }
        return out
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

    // MARK: Small parsing helpers

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
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let (key, value) = entry(of: line) else { return nil }
        if key.lowercased().hasPrefix("string") { return ("String", value) }
        return (key, value)
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

    private static func parseHex(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
        return Int(t, radix: 16)
    }
}
