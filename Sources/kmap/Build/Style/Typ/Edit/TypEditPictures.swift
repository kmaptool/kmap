import Foundation

extension TypEdit {
    /// Replaces the picture block; every other line of the section stays where it was.
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
        // A point's day picture unless night is named: the first block may be `NightXpm`.
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

    /// `.day` drops the night slots; `.night` moves them into the day slots, keeping the
    /// day palette keys the pixel rows address. Returns the number of elements changed.
    static func keeping(_ wanted: Theme, in text: String) -> (text: String, elements: Int) {
        guard wanted != .all else { return (text, 0) }
        let source = TypSource.parse(text)
        var lines = source.lines
        var elements = 0

        for section in source.sections.sorted(by: { $0.lines.lowerBound > $1.lines.lowerBound }) {
            // Bottom up, here and across sections, so no edit shifts a range not yet applied.
            var edits = labelColourEdits(section, in: source, keeping: wanted)
            let night = nightBlockEdits(section, in: source, keeping: wanted)
            edits += night.edits
            if section.kind != .point, !night.dayPictureReplaced,
                let edit = paletteHalfEdit(section, in: source, keeping: wanted)
            {
                edits.append(edit)
            }

            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                lines.replaceSubrange(edit.range, with: edit.replacement)
            }
            if !edits.isEmpty { elements += 1 }
        }
        return (lines.joined(separator: "\n"), elements)
    }

    /// Against the line numbers of the source as read.
    typealias LineEdit = (range: Range<Int>, replacement: [String])

    /// The label colour: by night it takes the night value, by day the night line goes.
    static func labelColourEdits(
        _ section: TypSection,
        in source: TypSource,
        keeping wanted: Theme
    ) -> [LineEdit] {
        var edits: [LineEdit] = []
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
            // The compiler takes the later of 2 DayCustomColor lines, so the original goes.
            for number in section.lines
            where TypSource.sets("DayCustomColor", source.lines[number]) {
                edits.append((number..<number + 1, []))
            }
        }
        return edits
    }

    /// A point keeps night in a second block: by day it goes, by night it replaces the day one.
    static func nightBlockEdits(
        _ section: TypSection,
        in source: TypSource,
        keeping wanted: Theme
    ) -> (edits: [LineEdit], dayPictureReplaced: Bool) {
        var edits: [LineEdit] = []
        var dayPictureReplaced = false
        // Every night block goes: one left would still be drawn after dark.
        let nightRanges = pictureLineRanges(in: source, section: section, tag: "NightXpm")
        if !nightRanges.isEmpty {
            // By its own tag: the night block may come first in the section.
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
                // mkgmap fails on a point drawn by night alone, so its night picture
                // becomes the day's, by either theme.
                let indent = indentation(of: source.lines[last.lowerBound])
                edits += nightRanges.dropLast().map { ($0, []) }
                edits.append((last, render(nightBlock, tag: "Xpm", indent: indent)))
                dayPictureReplaced = true
            } else {
                edits += nightRanges.map { ($0, []) }
            }
        }
        return (edits, dayPictureReplaced)
    }

    /// Everything but a point keeps night in the back half of its palette: cut to the day
    /// half, with the night colours moved in by night.
    static func paletteHalfEdit(_ section: TypSection, in source: TypSource, keeping wanted: Theme) -> LineEdit? {
        let slots = section.colourSlots
        guard !slots.night.isEmpty, let block = section.xpm,
            let extent = pictureLineRange(in: source, section: section, tag: nil)
        else { return nil }
        let day = slots.day.count
        let dayPair = Array(block.palette.prefix(day))
        let nightPair = Array(block.palette.dropFirst(day))
        // mkgmap draws a pattern by bits, ink first, moving a clear ink behind the other
        // colour for day and night apart, so night and day keys pair by bit.
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
        // A night key becomes the day key of its bit, or the pixel names a colour the cut
        // palette lacks.
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
        return (extent, render(kept, tag: tag, indent: indent))
    }

    /// A solid grows from 1 colour to 2, a pattern or cased line from 2 to 4. The new
    /// colours copy the day ones; the pixel rows name only day keys and stay untouched.
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
        // Any other shape is not one the compiler documents.
        let dayCount = section.colourSlots.day.count
        guard block.palette.count == dayCount,
            dayCount == 2 || (dayCount == 1 && block.isSolid)
        else {
            throw EditError.noNightForm(code)
        }

        let used = Set(block.palette.map(\.key))
        // `2` after `1`, `3` and `4` after a pair; other keys only when those are taken.
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

    /// A copy of the day picture, written straight after it, so the night picture's colours
    /// can then be set apart.
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

    /// mkgmap writes a day picture for every point, and fails on one that has none.
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
