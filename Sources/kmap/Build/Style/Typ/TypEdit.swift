import Foundation

/// Line-level edits to a TYP source file.
///
/// The parsed model is never written back: the original text is held verbatim, named
/// lines are replaced, and every other line arrives at the other end byte for byte.
/// Comments in the source carry provenance the binary format cannot hold.
enum TypEdit {

    enum EditError: LocalizedError {
        case noSuchSection(MapElementKind, Int)
        case noPicture(Int)
        case noSuchColour(Int, Int)
        case notAColour(String)
        case noDrawOrder
        case notALevel(Int)
        case noNightForm(Int)

        var errorDescription: String? {
            switch self {
            case .noDrawOrder:
                return t("this TYP declares no draw order")
            case .notALevel(let level):
                return t("%d is not a draw-order level — the lowest is 1", level)
            case .noNightForm(let code):
                return t("%@ has no night form: a pattern needs an ink and a background"
                         + " before night can be added — give it a background first",
                         TypeMeaning.hex(code))
            case .noSuchSection(let kind, let code):
                return t("this TYP has no %1$@ section for %2$@",
                         kind.rawValue, TypeMeaning.hex(code))
            case .noPicture(let code):
                return t("%@ has no Xpm block to change", TypeMeaning.hex(code))
            case .noSuchColour(let code, let index):
                return t("%1$@ has no colour %2$d", TypeMeaning.hex(code), index + 1)
            case .notAColour(let text):
                return t("%@ is not a #RRGGBB colour", text)
            }
        }
    }

    // MARK: Colours

    /// Replaces one entry of a section's palette, keeping its key and the pixels that
    /// reference it.
    ///
    /// The key is not touched: pixel rows address colours by that character, and a row
    /// pointing at a missing key comes out transparent.
    ///
    /// - Parameter tag: which `Xpm` block, for a point that keeps a night picture in a
    ///   second one. Nil takes whichever comes first.
    /// - Throws: `EditError.noSuchSection`, `.noSuchColour` or `.notAColour`.
    static func setColour(in source: TypSource, kind: MapElementKind, code: Int,
                          colourIndex: Int, to colour: String?,
                          tag: String? = nil) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
        let value = try normalize(colour)

        guard let paletteLines = paletteLineNumbers(in: source, section: section, tag: tag),
              colourIndex >= 0, colourIndex < paletteLines.count else {
            throw EditError.noSuchColour(code, colourIndex)
        }
        let lineNumber = paletteLines[colourIndex]
        let original = source.lines[lineNumber]
        guard let key = paletteKey(of: original,
                                   charsPerPixel: charsPerPixel(of: section, tag: tag)) else {
            throw EditError.noSuchColour(code, colourIndex)
        }

        var lines = source.lines
        lines[lineNumber] = indentation(of: original) + "\"\(key) c \(value)\""
        return lines.joined(separator: "\n")
    }

    // MARK: Labels

    /// Replaces the `String=` text for one language, or adds the line where the section has
    /// no entry in that language yet.
    ///
    /// A new line goes immediately after the last `String=` in the section, keeping the
    /// labels together.
    static func setLabel(in source: TypSource, kind: MapElementKind, code: Int,
                         language: Int, to text: String) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
        let wanted = String(format: "0x%02x", language)
        var lines = source.lines
        var lastLabelLine: Int?

        for number in section.lines {
            let line = lines[number].trimmingCharacters(in: .whitespaces)
            // `String1=` is the numbered spelling other tools write, and is replaced in
            // place rather than doubled by a plain `String=`.
            let lowered = line.lowercased()
            guard let eq = line.firstIndex(of: "="),
                  lowered.hasPrefix("string"),
                  line[line.startIndex..<eq].dropFirst("string".count)
                      .allSatisfy(\.isNumber) else { continue }
            lastLabelLine = number
            let value = line[line.index(after: eq)...]
            guard let comma = value.firstIndex(of: ","),
                  let parsed = Int(value[value.startIndex..<comma]
                    .trimmingCharacters(in: .whitespaces).dropFirst(2), radix: 16),
                  parsed == language else { continue }
            lines[number] = indentation(of: lines[number]) + "String=\(wanted),\(text)"
            return lines.joined(separator: "\n")
        }

        let insertAt = (lastLabelLine ?? (section.lines.upperBound - 2)) + 1
        let indent = lastLabelLine.map { indentation(of: lines[$0]) } ?? ""
        lines.insert(indent + "String=\(wanted),\(text)", at: insertAt)
        return lines.joined(separator: "\n")
    }

    // MARK: How the label is set

    /// Sets or removes `FontStyle`.
    ///
    /// The tag absent leaves the size to the receiver, which is a different instruction
    /// from naming the default size.
    static func setFontStyle(in source: TypSource, kind: MapElementKind, code: Int,
                             to style: String?) throws -> String {
        try setTag("FontStyle", in: source, kind: kind, code: code, to: style)
    }

    /// Sets or removes the label's own colour, by day or by night.
    ///
    /// Not the colour the element is drawn in. Without this tag the label is coloured by
    /// the receiver, which differs from naming the element's own colour.
    static func setLabelColour(in source: TypSource, kind: MapElementKind, code: Int,
                               night: Bool, to colour: String?) throws -> String {
        // Nil removes the tag; anything else must be a real colour, since the TYP
        // compiler rejects the tag otherwise.
        var value: String?
        if let colour {
            let normalized = try normalize(colour)
            guard normalized != "none" else { throw EditError.notAColour(colour) }
            value = normalized
        }
        return try setTag(night ? "NightCustomColor" : "DayCustomColor",
                          in: source, kind: kind, code: code, to: value)
    }

    /// Replaces a single-value tag in a section, adds it where there is none, or takes it
    /// out when the value is nil.
    ///
    /// A new tag is added before `[end]` rather than at the top, leaving the section's
    /// opening comments in place.
    private static func setTag(_ tag: String, in source: TypSource, kind: MapElementKind,
                               code: Int, to value: String?) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
        var lines = source.lines
        let existing = section.lines.first {
            lines[$0].trimmingCharacters(in: .whitespaces).lowercased()
                .hasPrefix(tag.lowercased() + "=")
        }

        guard let value else {
            if let existing { lines.remove(at: existing) }
            return lines.joined(separator: "\n")
        }
        if let existing {
            lines[existing] = indentation(of: lines[existing]) + "\(tag)=\(value)"
        } else {
            let end = section.lines.upperBound - 1
            lines.insert(indentation(of: lines[end]) + "\(tag)=\(value)", at: end)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Adding what is not there

    enum AddError: LocalizedError {
        case alreadyThere(MapElementKind, Int)

        var errorDescription: String? {
            switch self {
            case .alreadyThere(let kind, let code):
                return t("this TYP already has a %1$@ section for %2$@",
                         kind.rawValue, TypeMeaning.hex(code))
            }
        }
    }

    /// Creates a section for a type the file does not style yet.
    ///
    /// A code without a section is drawn by the receiver as it likes. A polygon also gets
    /// a `[_drawOrder]` entry: a polygon absent from that table is not drawn at all.
    static func addSection(in source: TypSource, kind: MapElementKind, code: Int,
                           colour: String = "#FF00FF", label: String? = nil,
                           drawOrderLevel: Int? = nil) throws -> String {
        guard source.section(kind, code) == nil else {
            throw AddError.alreadyThere(kind, code)
        }

        var lines = source.lines
        if kind == .polygon {
            insertIntoDrawOrder(&lines, code: code, level: drawOrderLevel)
        }

        if let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append(contentsOf: newSection(kind: kind, code: code, colour: colour,
                                            label: label))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A deliberately conspicuous starting section: magenta, and for a point a hollow
    /// square rather than an icon.
    private static func newSection(kind: MapElementKind, code: Int, colour: String,
                                   label: String?) -> [String] {
        var out = [kind.typSection, "Type=\(TypeMeaning.hex(code))"]
        out.append("; Added by kmap. Magenta until it is drawn: a new section is not a "
                   + "finished one.")

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

    /// Puts a polygon into the draw order, at the level asked for or on top of everything.
    private static func insertIntoDrawOrder(_ lines: inout [String], code: Int, level: Int?) {
        guard let table = drawOrderTable(in: lines) else { return }
        // The highest level in the table, so a new polygon lands above ground cover
        // rather than hidden beneath it.
        let highest = lines[table].compactMap { drawOrderEntry(of: $0)?.level }.max() ?? 1
        placeInDrawOrder(&lines, table: table, entry: "Type=\(TypeMeaning.hex(code))",
                         level: level ?? highest, note: "; added by kmap")
    }

    /// Moves a polygon to another level of the draw order, or adds a missing one.
    ///
    /// The entry is written among the others of its new level, so a table kept in level
    /// order stays that way. The code keeps its spelling; kmap's own note above the
    /// entry moves with it.
    /// - Throws: `EditError.noDrawOrder` without a table, `.notALevel` below 1.
    static func setDrawOrderLevel(in source: TypSource, code: Int, to level: Int) throws
        -> String {
        guard level >= 1 else { throw EditError.notALevel(level) }
        var lines = source.lines
        guard let table = drawOrderTable(in: lines) else { throw EditError.noDrawOrder }

        var spelling = "Type=\(TypeMeaning.hex(code))"
        var note: String?
        if let number = table.first(where: { drawOrderEntry(of: lines[$0])?.code == code }) {
            spelling = drawOrderEntry(of: lines[number])?.spelling ?? spelling
            // Only kmap's own note moves: a divider above the entry belongs to the group.
            if number > table.lowerBound,
               lines[number - 1].trimmingCharacters(in: .whitespaces).lowercased()
                   == "; added by kmap" {
                note = "; added by kmap"
            }
        }
        removeFromDrawOrder(&lines, code: code)
        guard let again = drawOrderTable(in: lines) else { throw EditError.noDrawOrder }
        placeInDrawOrder(&lines, table: again, entry: spelling, level: level, note: note)
        return lines.joined(separator: "\n")
    }

    /// Writes an entry after the last one at or below its level, or at the top where
    /// none is. The note goes on its own line: the TYP compiler reads an entry to the
    /// end of the line, and a comment behind the level breaks the whole file.
    private static func placeInDrawOrder(_ lines: inout [String], table: Range<Int>,
                                         entry: String, level: Int, note: String?) {
        var at = table.lowerBound
        for number in table {
            guard let entry = drawOrderEntry(of: lines[number]), entry.level <= level
            else { continue }
            at = number + 1
        }
        let indent = table.isEmpty ? "" : indentation(of: lines[table.lowerBound])
        var written = [indent + "\(entry),\(level)"]
        if let note { written.insert(indent + note, at: 0) }
        lines.insert(contentsOf: written, at: at)
    }

    /// The lines between `[_drawOrder]` and its `[end]`, exclusive; nil without a table.
    private static func drawOrderTable(in lines: [String]) -> Range<Int>? {
        guard let open = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "[_draworder]"
        }) else { return nil }
        guard let close = lines[open...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "[end]"
        }) else { return nil }
        return open + 1..<close
    }

    // MARK: Taking out what is there

    /// Removes a section; the device then draws that type its own way.
    ///
    /// The block goes from its header through `[end]` with one adjacent blank line, so
    /// no double gap is left. Comments above the header stay: a divider like
    /// `; --- water ---` cannot be told from a note about the section. A polygon's
    /// `[_drawOrder]` entries go with it.
    static func removeSection(in source: TypSource, kind: MapElementKind, code: Int) throws
        -> String {
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

    /// Removes every draw-order entry for a polygon, with kmap's own note above it.
    private static func removeFromDrawOrder(_ lines: inout [String], code: Int) {
        guard let table = drawOrderTable(in: lines) else { return }
        var going: Set<Int> = []
        for number in table where drawOrderEntry(of: lines[number])?.code == code {
            going.insert(number)
            if number > table.lowerBound,
               lines[number - 1].trimmingCharacters(in: .whitespaces).lowercased()
                   == "; added by kmap" {
                going.insert(number - 1)
            }
        }
        for number in going.sorted(by: >) { lines.remove(at: number) }
    }

    /// An entry like `Type=0x04b,5`: the type, its level (0 where none is given) and the
    /// type as spelt in the file. Nil for any other line. A comment behind the level,
    /// which an older kmap wrote, does not hide the entry.
    private static func drawOrderEntry(of line: String)
        -> (code: Int, level: Int, spelling: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("type="), let eq = trimmed.firstIndex(of: "=")
        else { return nil }
        let value = trimmed[trimmed.index(after: eq)...].prefix { $0 != ";" }
        let parts = value.split(separator: ",", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else { return nil }
        let digits = first.lowercased().hasPrefix("0x") ? String(first.dropFirst(2)) : first
        guard let code = Int(digits, radix: 16) else { return nil }
        let level = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return (code, level, "Type=\(first)")
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Finding things inside a section

    /// Line numbers of the palette entries of a section's picture, in declaration order.
    private static func paletteLineNumbers(in source: TypSource, section: TypSection,
                                           tag: String? = nil) -> [Int]? {
        guard let extent = pictureLineRange(in: source, section: section, tag: tag) else {
            return nil
        }
        let declared = charsCount(of: section, tag: tag)
        var out: [Int] = []
        for number in extent.dropFirst() where out.count < declared {
            guard source.lines[number].trimmingCharacters(in: .whitespaces).hasPrefix("\"")
            else { break }
            out.append(number)
        }
        return out
    }

    /// The full extent of an `Xpm=` block: the tag line and every quoted line under it.
    static func pictureLineRange(in source: TypSource, section: TypSection,
                                         tag wanted: String? = nil) -> Range<Int>? {
        var start: Int?
        for number in section.lines {
            guard let found = pictureTag(of: source.lines[number]) else { continue }
            // A point keeps its night picture in a second block, so the requested tag
            // must match rather than the first block found.
            if let wanted, found.lowercased() != wanted.lowercased() { continue }
            start = number
            break
        }
        guard let start else { return nil }

        var end = start + 1
        while end < section.lines.upperBound,
              source.lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("\"") {
            end += 1
        }
        return start..<end
    }

    /// `Xpm`, `DayXpm` or `NightXpm` where the line opens one, otherwise nil.
    static func pictureTag(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for tag in ["DayXpm", "NightXpm", "Xpm"] where trimmed.lowercased()
            .hasPrefix(tag.lowercased() + "=") {
            return tag
        }
        return nil
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
        return "#" + text.replacingOccurrences(of: "#", with: "").uppercased()
    }
}
