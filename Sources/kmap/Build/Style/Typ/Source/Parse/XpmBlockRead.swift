import Foundation

/// A picture read from a TYP source: its header, its palette and its rows.
extension XpmBlock {
    /// Reads an Xpm header and the quoted lines under it. Returns the block and the index
    /// of the first line that is no longer part of it.
    static func read(
        header: String,
        following body: [String],
        from start: Int
    ) -> (XpmBlock?, Int) {
        // Between the first 2 quotes, as mkgmap reads it: a note after may hold quotes too.
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let numbers = (trimmed.hasPrefix("\"") ? TypSource.firstQuoted(trimmed) : trimmed)
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
            if palette.count < declared, let entry = paletteEntry(line, keyLength: perPixel) {
                palette.append(entry)
            } else {
                // A row is as wide as the picture, as mkgmap takes it, whatever follows; a
                // true-colour row names its colours and is read whole.
                let inside = line.dropFirst()
                // A wild width is a typo: its product with the key width would overflow.
                let (wide, overflowed) = width.multipliedReportingOverflow(by: max(1, perPixel))
                rows.append(
                    declared > 0 && !overflowed && wide > 0 && inside.count >= wide
                        ? String(inside.prefix(wide)) : TypSource.unquote(line)
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
    static func paletteEntry(
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
        paletteEntry(line.trimmingCharacters(in: .whitespaces), keyLength: keyLength) != nil
    }

    /// The last `<word>alpha=N` after a palette line's closing quote, as mkgmap reads it: a
    /// word ending in `alpha`, TYPViewer's `canalalpha` too, then `=` and a number.
    static func alpha(in tail: String) -> Int? {
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
                if let level = TypSource.decodedInteger(String(number)) { found = level }
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
}
