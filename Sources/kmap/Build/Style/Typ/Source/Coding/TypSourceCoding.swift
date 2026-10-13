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
}
