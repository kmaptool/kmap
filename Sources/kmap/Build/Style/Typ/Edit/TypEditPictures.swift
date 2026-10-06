import Foundation

/// Editing a section's whole pictures: replacing an XPM, resizing it, and the day
/// and night variants.
extension TypEdit {
    /// Replaces a section's `Xpm` / `DayXpm` block (header, palette and pixel rows),
    /// leaving every other line of the section where it was.
    static func setPicture(
        in source: TypSource,
        kind: MapElementKind,
        code: Int,
        to block: XpmBlock,
        tag wanted: String? = nil
    ) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
        // A point's picture is its day one unless the night is asked for by name: the
        // first block in the section may be its `NightXpm`.
        let wanted = wanted ?? (kind == .point ? (section.dayXpm != nil ? "DayXpm" : "Xpm") : nil)
        guard let extent = pictureLineRange(in: source, section: section, tag: wanted) else {
            throw EditError.noPicture(code)
        }
        let indent = indentation(of: source.lines[extent.lowerBound])
        let tag = pictureTag(of: source.lines[extent.lowerBound]) ?? "Xpm"

        var lines = source.lines
        lines.replaceSubrange(extent, with: render(block, tag: tag, indent: indent))
        return lines.joined(separator: "\n")
    }

    /// An `Xpm` block as the TYP compiler wants it written.
    static func render(_ block: XpmBlock, tag: String, indent: String = "") -> [String] {
        var out = [
            indent + "\(tag)=\"\(block.width) \(block.height) "
                + "\(block.declaredColours) \(block.charsPerPixel)\""
        ]
        for entry in block.palette {
            out.append(indent + "\"\(entry.key) c \(entry.colour ?? "none")\"")
        }
        for row in block.rows {
            out.append(indent + "\"\(row)\"")
        }
        return out
    }

    /// A TYP with one of its two drawings taken out, and the number of elements changed.
    ///
    /// `.day` drops the night slots; `.night` moves them into the day slots, keeping the
    /// day palette keys the pixel rows address. Sections are edited bottom upwards so the
    /// line numbers of those not yet reached stay valid.
    static func keeping(_ wanted: Theme, in text: String) -> (text: String, elements: Int) {
        guard wanted != .all else { return (text, 0) }
        let source = TypSource.parse(text)
        var lines = source.lines
        var elements = 0

        for section in source.sections.sorted(by: { $0.lines.lowerBound > $1.lines.lowerBound }) {
            // Edits are expressed against the original line numbers and applied at the
            // end, highest first, so earlier removals do not shift later ranges.
            var edits: [(range: Range<Int>, replacement: [String])] = []

            // The label's own colour: by night it takes the night value, by day the
            // night line simply goes.
            var convertedNightColour = false
            for number in section.lines {
                guard let (key, value) = TypSource.entry(of: source.lines[number]),
                    key.caseInsensitiveCompare("NightCustomColor") == .orderedSame
                else { continue }
                if wanted == .night {
                    edits.append(
                        (
                            number..<number + 1,
                            [
                                indentation(of: source.lines[number])
                                    + "DayCustomColor=" + value
                            ]
                        )
                    )
                    convertedNightColour = true
                } else {
                    edits.append((number..<number + 1, []))
                }
            }
            if convertedNightColour {
                // Two DayCustomColor lines now stand; the compiler takes the later one,
                // so the original is dropped.
                for number in section.lines
                where TypSource.sets("DayCustomColor", source.lines[number]) {
                    edits.append((number..<number + 1, []))
                }
            }

            // A point keeps night in a second block: by day it goes, by night it replaces
            // the day block, rows and palette together.
            var dayPictureReplaced = false
            // Every night block goes: one left would still be drawn after dark.
            let nightRanges = pictureLineRanges(in: source, section: section, tag: "NightXpm")
            if !nightRanges.isEmpty {
                // The day block by its own tag: the night one may come first in the section.
                if wanted == .night, let nightBlock = section.nightXpm,
                    let dayRange = pictureLineRange(
                        in: source,
                        section: section,
                        tag: section.dayXpm != nil ? "DayXpm" : "Xpm"
                    )
                {
                    let indent = indentation(of: source.lines[dayRange.lowerBound])
                    let tag = pictureTag(of: source.lines[dayRange.lowerBound]) ?? "Xpm"
                    edits += nightRanges.map { ($0, []) }
                    edits.append((dayRange, render(nightBlock, tag: tag, indent: indent)))
                    dayPictureReplaced = true
                } else if section.dayXpm ?? section.xpm == nil, let last = nightRanges.last,
                    let nightBlock = section.nightXpm
                {
                    // A point drawn by night alone: mkgmap writes a day picture it does not
                    // have and fails. Its night picture becomes the day's, by either theme.
                    let indent = indentation(of: source.lines[last.lowerBound])
                    edits += nightRanges.dropLast().map { ($0, []) }
                    edits.append((last, render(nightBlock, tag: "Xpm", indent: indent)))
                    dayPictureReplaced = true
                } else {
                    edits += nightRanges.map { ($0, []) }
                }
            }

            // Everything else keeps night in the back half of one palette.
            if section.kind != .point, !dayPictureReplaced {
                let slots = section.colourSlots
                if !slots.night.isEmpty, let block = section.xpm,
                    let extent = pictureLineRange(in: source, section: section, tag: nil)
                {
                    let day = slots.day.count
                    let dayPair = Array(block.palette.prefix(day))
                    let nightPair = Array(block.palette.dropFirst(day))
                    // mkgmap draws a pattern by bits, ink first, and puts a clear ink behind its
                    // pair's other colour, by day and by night apart: a pixel's night colour is
                    // the one with its bit, and a night key draws as the day key with its bit.
                    let pattern = !block.isSolid && day == 2 && nightPair.count == 2
                    func order(_ pair: [(key: String, colour: String?)]) -> [Int] {
                        pattern && pair[0].colour == nil ? [1, 0] : Array(pair.indices)
                    }
                    let dayBits = order(dayPair)
                    let nightBits = order(nightPair)
                    var palette = dayPair
                    if wanted == .night {
                        for (at, entry) in dayPair.enumerated() {
                            guard let bit = dayBits.firstIndex(of: at), bit < nightBits.count else { continue }
                            palette[at] = (key: entry.key, colour: nightPair[nightBits[bit]].colour)
                        }
                    }
                    // mkgmap refuses a solid all clear: it shows the colour the other half has.
                    if block.isSolid, palette.allSatisfy({ $0.colour == nil }),
                        let shown = block.palette.first(where: { $0.colour != nil })?.colour
                    {
                        palette[0].colour = shown
                    }
                    // A pixel drawn with a night key takes the day key of its bit, or it names
                    // a colour the cut palette no longer has.
                    var dayKey: [String: String] = [:]
                    // In bit order, as mkgmap indexes: of 2 entries with one key, the later wins.
                    for (bit, at) in nightBits.enumerated() where bit < dayBits.count {
                        dayKey[nightPair[at].key] = dayPair[dayBits[bit]].key
                    }
                    let width = max(1, block.charsPerPixel)
                    let rows =
                        dayKey.isEmpty
                        ? block.rows
                        : block.rows.map { row in
                            var out = ""
                            var rest = Substring(row)
                            while !rest.isEmpty {
                                let pixel = String(rest.prefix(width))
                                out += dayKey[pixel] ?? pixel
                                rest = rest.dropFirst(width)
                            }
                            return out
                        }
                    let kept = XpmBlock(
                        width: block.width,
                        height: block.height,
                        declaredColours: palette.count,
                        charsPerPixel: block.charsPerPixel,
                        palette: palette,
                        rows: rows
                    )
                    let indent = indentation(of: source.lines[extent.lowerBound])
                    let tag = pictureTag(of: source.lines[extent.lowerBound]) ?? "Xpm"
                    edits.append((extent, render(kept, tag: tag, indent: indent)))
                }
            }

            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                lines.replaceSubrange(edit.range, with: edit.replacement)
            }
            if !edits.isEmpty { elements += 1 }
        }
        return (lines.joined(separator: "\n"), elements)
    }

    /// Gives an element night colours where it has only day ones.
    ///
    /// A solid with one colour grows to two; a pattern or a cased line with two grows to
    /// four. The new colours copy the day ones; the pixel rows only name the day keys
    /// and are untouched.
    static func addNightColours(
        in source: TypSource,
        kind: MapElementKind,
        code: Int
    ) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
        guard kind != .point else {
            // A point keeps its night version in a second block, not in more palette.
            return try addNightPicture(in: source, code: code)
        }
        guard let block = section.xpm else { throw EditError.noPicture(code) }
        guard section.colourSlots.night.isEmpty else {
            throw AddError.alreadyThere(kind, code)
        }
        // Day takes one colour for a plain solid, two for a pattern or a cased line, as
        // `colourSlots` decided. Anything else is not a shape the compiler documents.
        let dayCount = section.colourSlots.day.count
        guard block.palette.count == dayCount,
            dayCount == 2 || (dayCount == 1 && block.isSolid)
        else {
            throw EditError.noNightForm(code)
        }

        let used = Set(block.palette.map(\.key))
        // Conventional keys follow the day ones by number: `2` after `1`, `3` and `4`
        // after a pair. Other keys only when those are taken.
        var keys: [String] = []
        let conventional = (dayCount + 1...dayCount * 2).map(String.init)
        for candidate in conventional + XpmBlock.keyAlphabet.map(String.init)
        where keys.count < dayCount {
            guard !used.contains(candidate), !keys.contains(candidate),
                candidate.count == max(1, block.charsPerPixel)
            else { continue }
            keys.append(candidate)
        }
        guard keys.count == dayCount else { throw EditError.noPicture(code) }

        var palette = block.palette
        for (key, day) in zip(keys, block.palette) {
            palette.append((key: key, colour: day.colour))
        }

        let grown = XpmBlock(
            width: block.width,
            height: block.height,
            declaredColours: palette.count,
            charsPerPixel: block.charsPerPixel,
            palette: palette,
            rows: block.rows
        )
        return try setPicture(in: source, kind: kind, code: code, to: grown, tag: "Xpm")
    }

    /// Gives a point a night picture, drawn the same as its day one.
    ///
    /// A point with no `NightXpm` is shown after dark exactly as by day. The new block
    /// copies the day picture's rows and palette and is written straight after it.
    static func addNightPicture(in source: TypSource, code: Int) throws -> String {
        guard let section = source.section(.point, code) else {
            throw EditError.noSuchSection(.point, code)
        }
        // A point's plain `Xpm=` is its day picture, as mkgmap reads it.
        let dayTag = section.dayXpm != nil ? "DayXpm" : "Xpm"
        guard let day = section.dayXpm ?? section.xpm else { throw EditError.noPicture(code) }
        guard section.nightXpm == nil else {
            throw AddError.alreadyThere(.point, code)
        }
        guard let extent = pictureLineRange(in: source, section: section, tag: dayTag) else {
            throw EditError.noPicture(code)
        }

        var lines = source.lines
        let indent = indentation(of: lines[extent.lowerBound])
        var block = [indent + "; The same drawing after dark. Only the colours differ."]
        block.append(contentsOf: render(day, tag: "NightXpm", indent: indent))
        lines.insert(contentsOf: block, at: extent.upperBound)
        return lines.joined(separator: "\n")
    }

    /// Every point drawn by night alone also drawn so by day: mkgmap writes a day picture
    /// for every point, and fails on one that has none.
    static func givingNightOnlyPointsADay(_ text: String) -> String {
        let source = TypSource.parse(text)
        var lines = source.lines
        let lonely = source.sections.filter {
            $0.kind == .point && $0.dayXpm == nil && $0.xpm == nil && $0.nightXpm != nil
        }
        guard !lonely.isEmpty else { return text }
        for section in lonely.sorted(by: { $0.lines.lowerBound > $1.lines.lowerBound }) {
            guard let night = section.nightXpm,
                let last = pictureLineRanges(in: source, section: section, tag: "NightXpm").last
            else { continue }
            lines.insert(
                contentsOf: render(night, tag: "Xpm", indent: indentation(of: lines[last.lowerBound])),
                at: last.lowerBound
            )
        }
        return lines.joined(separator: "\n")
    }
}
