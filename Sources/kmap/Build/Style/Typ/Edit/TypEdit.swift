import Foundation

/// Line-level edits to a TYP source file.
///
/// The parsed model is never written back: the original text is held verbatim, named
/// lines are replaced, and every other line arrives at the other end byte for byte.
/// Comments in the source carry provenance the binary format cannot hold.
enum TypEdit {
    // MARK: Colours

    /// Replaces one entry of a section's palette, keeping its key and the pixels that
    /// reference it.
    ///
    /// The key is not touched: pixel rows address colours by that character, and a row
    /// pointing at a missing key comes out transparent.
    ///
    /// - Parameter tag: which `Xpm` block, for a point that keeps a night picture in a
    ///   second one. Nil is the day picture, as the parse takes it.
    /// - Throws: `EditError.noSuchSection`, `.noSuchColour` or `.notAColour`.
    static func setColour(
        in source: TypSource,
        kind: MapElementKind,
        code: Int,
        colourIndex: Int,
        to colour: String?,
        tag: String? = nil
    ) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
        var value = try normalize(colour)

        guard let paletteLines = paletteLineNumbers(in: source, section: section, tag: tag),
            colourIndex >= 0, colourIndex < paletteLines.count
        else {
            throw EditError.noSuchColour(code, colourIndex)
        }
        let lineNumber = paletteLines[colourIndex]
        let original = source.lines[lineNumber]
        guard
            let key = paletteKey(
                of: original,
                charsPerPixel: charsPerPixel(of: section, tag: tag)
            )
        else {
            throw EditError.noSuchColour(code, colourIndex)
        }

        value =
            keepingAlpha(value, typed: colour, of: block(of: section, tag: tag)?.palette[safe: colourIndex]?.colour)
            ?? "none"
        var lines = source.lines
        lines[lineNumber] = indentation(of: original) + "\"\(key) c \(value)\""
        let edited = lines.joined(separator: "\n")
        // Refused here, not by mkgmap at the next build; read back as the parser reads it,
        // so a clear alpha counts as clear.
        if kind != .point, let after = TypSource.parse(edited).section(kind, code),
            let colours = block(of: after, tag: tag)?.palette.map(\.colour), let refused = refusal(ofSimple: colours)
        {
            throw refused
        }
        return edited
    }

    // MARK: Labels

    /// Replaces the `String=` text for one language, or adds the line where the section has
    /// no entry in that language yet.
    ///
    /// A new line goes immediately after the last `String=` in the section, keeping the
    /// labels together.
    static func setLabel(
        in source: TypSource,
        kind: MapElementKind,
        code: Int,
        language: Int,
        to text: String
    ) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
        let wanted = String(format: "0x%02x", language)
        var lines = source.lines
        var lastLabelLine: Int?

        for number in section.lines {
            // `String1=` is the numbered spelling other tools write, and is replaced in
            // place rather than doubled by a plain `String=`.
            guard let (key, value) = TypSource.entry(of: lines[number]), key.lowercased().hasPrefix("string")
            else { continue }
            lastLabelLine = number
            guard TypSource.label(in: value).language == language else { continue }
            lines[number] = indentation(of: lines[number]) + "String=\(wanted),\(text)"
            return lines.joined(separator: "\n")
        }

        let insertAt = lastLabelLine.map { $0 + 1 } ?? closingLine(of: section, in: lines)
        let indent = lastLabelLine.map { indentation(of: lines[$0]) } ?? ""
        lines.insert(indent + "String=\(wanted),\(text)", at: insertAt)
        return lines.joined(separator: "\n")
    }

    // MARK: How the label is set

    /// Sets or removes `FontStyle`.
    ///
    /// The tag absent leaves the size to the receiver, which is a different instruction
    /// from naming the default size.
    static func setFontStyle(
        in source: TypSource,
        kind: MapElementKind,
        code: Int,
        to style: String?
    ) throws -> String {
        try setTag("FontStyle", in: source, kind: kind, code: code, to: style)
    }

    /// Sets or removes the label's own colour, by day or by night.
    ///
    /// Not the colour the element is drawn in. Without this tag the label is coloured by
    /// the receiver, which differs from naming the element's own colour.
    static func setLabelColour(
        in source: TypSource,
        kind: MapElementKind,
        code: Int,
        night: Bool,
        to colour: String?
    ) throws -> String {
        // Nil removes the tag; anything else must be a real colour, since the TYP
        // compiler rejects the tag otherwise.
        var value: String?
        if let colour {
            let normalized = try normalize(colour)
            guard normalized != "none" else { throw EditError.notAColour(colour) }
            value = normalized
        }
        return try setTag(
            night ? "NightCustomColor" : "DayCustomColor",
            in: source,
            kind: kind,
            code: code,
            to: value
        )
    }

    /// Replaces a single-value tag in a section, adds it where there is none, or takes it out
    /// when the value is nil. A new tag goes at the section's end, before its `[end]` where it
    /// has one, leaving the section's opening comments in place.
    private static func setTag(
        _ tag: String,
        in source: TypSource,
        kind: MapElementKind,
        code: Int,
        to value: String?
    ) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
        var lines = source.lines
        // The last, as mkgmap takes the last; a removal takes them all.
        let matching = section.lines.filter { TypSource.sets(tag, lines[$0]) }
        let existing = matching.last

        guard let value else {
            for at in matching.reversed() { lines.remove(at: at) }
            return lines.joined(separator: "\n")
        }
        if let existing {
            lines[existing] = indentation(of: lines[existing]) + "\(tag)=\(value)"
        } else {
            let end = closingLine(of: section, in: lines)
            lines.insert(indentation(of: lines[end - 1]) + "\(tag)=\(value)", at: end)
        }
        return lines.joined(separator: "\n")
    }

    /// Where a line added at the end of a section goes: before its `[end]`, or after its
    /// last line where the next header closes it, as mkgmap allows.
    static func closingLine(of section: TypSection, in lines: [String]) -> Int {
        let last = section.lines.upperBound - 1
        let closed =
            last > section.lines.lowerBound
            && TypSource.header(of: lines[last]) == "[end]"
        return closed ? last : section.lines.upperBound
    }

    // MARK: Adding what is not there

    /// What a new section is painted with until somebody chooses: magenta, which no map
    /// uses, so the section shows as new.
    static let placeholderColour = "#FF00FF"

    /// Creates a section for a type the file does not style yet.
    ///
    /// A code without a section is drawn by the receiver as it likes. A polygon also gets
    /// a `[_drawOrder]` entry: a polygon absent from that table is not drawn at all.
    static func addSection(
        in source: TypSource,
        kind: MapElementKind,
        code: Int,
        colour: String = placeholderColour,
        label: String? = nil,
        drawOrderLevel: Int? = nil
    ) throws -> String {
        guard source.section(kind, code) == nil else {
            throw AddError.alreadyThere(kind, code)
        }

        var lines = source.lines
        if kind == .polygon {
            insertIntoDrawOrder(&lines, code: code, level: drawOrderLevel)
        }

        if let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append(
            contentsOf: newSection(
                kind: kind,
                code: code,
                colour: colour,
                label: label
            )
        )
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A deliberately conspicuous starting section: magenta, and for a point a hollow
    /// square rather than an icon.
    private static func newSection(
        kind: MapElementKind,
        code: Int,
        colour: String,
        label: String?
    ) -> [String] {
        var out = [kind.typSection, "Type=\(TypeMeaning.hex(code))"]
        out.append(
            "; Added by kmap. Magenta until it is drawn: a new section is not a "
                + "finished one."
        )

        let quote = "\""
        switch kind {
        case .point:
            // 20 by 20 pixels, the usual badge size on a Garmin map.
            let side = 20
            out.append("DayXpm=\(quote)\(side) \(side) 2 1\(quote)")
            out.append("\(quote)a c \(colour)\(quote)")
            out.append("\(quote). c none\(quote)")
            for row in 0..<side {
                let pixels = (0..<side).map { column -> String in
                    let edge = row == 0 || column == 0 || row == side - 1 || column == side - 1
                    return edge ? "a" : "."
                }.joined()
                out.append(quote + pixels + quote)
            }
        case .line:
            out.append("Xpm=\(quote)0 0 1 0\(quote)")
            out.append("\(quote)a c \(colour)\(quote)")
            out.append("LineWidth=2")
        case .polygon:
            out.append("Xpm=\(quote)0 0 1 0\(quote)")
            out.append("\(quote)a c \(colour)\(quote)")
        }

        if let label, !label.isEmpty {
            out.append("String=0x00,\(label)")
        }
        out.append("[end]")
        return out
    }

    // MARK: Taking out what is there

    /// Removes a section; the device then draws that type its own way.
    ///
    /// The block goes from its header through `[end]` with one adjacent blank line, so
    /// no double gap is left. Comments above the header stay: a divider like
    /// `; --- water ---` cannot be told from a note about the section. A polygon's
    /// `[_drawOrder]` entries go with it.
    static func removeSection(
        in source: TypSource,
        kind: MapElementKind,
        code: Int
    ) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
        var lines = source.lines
        var range = section.lines
        if range.upperBound < lines.count, isBlank(lines[range.upperBound]) {
            range = range.lowerBound..<range.upperBound + 1
        } else if range.lowerBound > 0, isBlank(lines[range.lowerBound - 1]) {
            range = range.lowerBound - 1..<range.upperBound
        }
        lines.removeSubrange(range)

        // Found by content, so the table may sit above or below the sections.
        if kind == .polygon {
            removeFromDrawOrder(&lines, code: code)
        }
        return lines.joined(separator: "\n")
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Finding things inside a section

    /// Line numbers of the palette entries of a section's picture, in declaration order.
    private static func paletteLineNumbers(
        in source: TypSource,
        section: TypSection,
        tag: String? = nil
    ) -> [Int]? {
        guard let extent = pictureLineRange(in: source, section: section, tag: tag) else {
            return nil
        }
        let declared = charsCount(of: section, tag: tag)
        let width = block(of: section, tag: tag)?.charsPerPixel ?? 1
        // The lines the parse took for the palette, a line it could not read left out.
        var out: [Int] = []
        for number in extent.dropFirst() where out.count < declared {
            let line = source.lines[number].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix("\"") else { break }
            if TypSource.isPaletteEntry(line, keyLength: width) { out.append(number) }
        }
        return out
    }

    /// The full extent of an `Xpm=` block: the tag line and every quoted line under it. The
    /// last block of the tag, as mkgmap takes the last.
    static func pictureLineRange(
        in source: TypSource,
        section: TypSection,
        tag wanted: String? = nil
    ) -> Range<Int>? {
        pictureLineRanges(in: source, section: section, tag: wanted).last
    }

    /// Every block of a tag in the section, in order. Nil is the picture drawn by day, as
    /// the parse takes it; a point keeps its night picture apart, so the tag must match.
    static func pictureLineRanges(
        in source: TypSource,
        section: TypSection,
        tag wanted: String? = nil
    ) -> [Range<Int>] {
        let wanted = wanted ?? (section.kind == .point && section.dayXpm != nil ? "DayXpm" : "Xpm")
        return section.lines.compactMap { number -> Range<Int>? in
            guard let found = pictureTag(of: source.lines[number]), found.lowercased() == wanted.lowercased() else {
                return nil
            }
            return number..<pictureEnd(in: source.lines, from: number + 1, before: section.lines.upperBound)
        }
    }

    /// Where a picture's quoted lines end: blank lines inside it are its own, as mkgmap
    /// looks past them for the next quote.
    static func pictureEnd(in lines: [String], from first: Int, before limit: Int) -> Int {
        var end = first
        var at = first
        while at < limit {
            let line = lines[at].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\"") {
                at += 1
                end = at
            } else if line.isEmpty {
                at += 1
            } else {
                break
            }
        }
        return end
    }

    /// `Xpm`, `DayXpm` or `NightXpm` where the line opens one, otherwise nil.
    static func pictureTag(of line: String) -> String? {
        ["DayXpm", "NightXpm", "Xpm"].first { TypSource.sets($0, line) }
    }

    private static func block(of section: TypSection, tag: String?) -> XpmBlock? {
        switch tag?.lowercased() {
        case "nightxpm": return section.nightXpm
        case "dayxpm": return section.dayXpm
        case "xpm": return section.xpm
        default: return section.dayXpm ?? section.xpm
        }
    }

    private static func charsPerPixel(of section: TypSection, tag: String? = nil) -> Int {
        max(1, block(of: section, tag: tag)?.charsPerPixel ?? 1)
    }

    private static func charsCount(of section: TypSection, tag: String? = nil) -> Int {
        block(of: section, tag: tag)?.declaredColours ?? 0
    }

    /// The palette key of a line like `"a c #F8FCF8"`, taken by width: a key may be any
    /// character, including a space, a semicolon or an apostrophe.
    private static func paletteKey(of line: String, charsPerPixel: Int) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\"") else { return nil }
        let body = trimmed.dropFirst()
        guard body.count >= charsPerPixel + 2 else { return nil }
        return String(body.prefix(charsPerPixel))
    }

    static func indentation(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// `#RRGGBB` upper-cased, or `none` for transparency.
    private static func normalize(_ colour: String?) throws -> String {
        guard let colour else { return "none" }
        let text = colour.trimmingCharacters(in: .whitespaces)
        if text.lowercased() == "none" { return "none" }
        guard Color.hex(text) != nil else { throw EditError.notAColour(text) }
        // As mkgmap holds it: an alpha of 00 shows nothing, and FF is no alpha at all.
        return TypSource.withAlpha(nil, on: "#" + text.replacingOccurrences(of: "#", with: "").uppercased()) ?? "none"
    }

    /// A new colour for a palette entry: a see-through one stays so, the new colour taking
    /// the old alpha where what was `typed` names none of its own.
    static func keepingAlpha(_ colour: String, typed: String?, of old: String?) -> String? {
        let digits = (typed ?? "").filter { $0.isASCII && $0.isHexDigit }
        guard colour.count == 7, digits.count == 6, let old, old.count == 9, Color.channels(of: old) != nil else {
            return colour == "none" ? nil : colour
        }
        return colour + old.suffix(2)
    }
}
