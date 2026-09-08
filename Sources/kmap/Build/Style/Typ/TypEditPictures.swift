import Foundation

/// Editing a section's whole pictures: replacing an XPM, resizing it, and the day
/// and night variants.
extension TypEdit {
    /// Replaces a section's `Xpm` / `DayXpm` block (header, palette and pixel rows),
    /// leaving every other line of the section where it was.
    static func setPicture(in source: TypSource, kind: MapElementKind, code: Int,
                           to block: XpmBlock, tag wanted: String? = nil) throws -> String {
        guard let section = source.section(kind, code) else {
            throw EditError.noSuchSection(kind, code)
        }
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
        var out = [indent + "\(tag)=\"\(block.width) \(block.height) "
                   + "\(block.declaredColours) \(block.charsPerPixel)\""]
        for entry in block.palette {
            out.append(indent + "\"\(entry.key) c \(entry.colour ?? "none")\"")
        }
        for row in block.rows {
            out.append(indent + "\"\(row)\"")
        }
        return out
    }

    /// Which of a TYP's two drawings a build keeps.
    ///
    /// Night is extra colours in the same element, not a separate section: a solid pair is
    /// day then night, four are day fill, day casing, night fill, night casing (or ink and
    /// background for a pattern), plus a second picture on a point and `NightCustomColor`.
    enum Theme: String, CaseIterable {
        /// The file as its author wrote it.
        case all
        /// Only what the file says about day; the night slots go.
        case day
        /// The night drawing moved into the day slots, so it shows at any hour.
        case night
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
                let trimmed = source.lines[number].trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("nightcustomcolor=") else { continue }
                if wanted == .night, let value = trimmed.split(separator: "=").last {
                    edits.append((number..<number + 1,
                                  [indentation(of: source.lines[number])
                                   + "DayCustomColor=" + value]))
                    convertedNightColour = true
                } else {
                    edits.append((number..<number + 1, []))
                }
            }
            if convertedNightColour {
                // Two DayCustomColor lines now stand; the compiler takes the later one,
                // so the original is dropped.
                for number in section.lines
                where source.lines[number].trimmingCharacters(in: .whitespaces)
                    .lowercased().hasPrefix("daycustomcolor=") {
                    edits.append((number..<number + 1, []))
                }
            }

            // A point keeps night in a second block: by day it goes, by night it replaces
            // the day block, rows and palette together.
            var dayPictureReplaced = false
            if let nightRange = pictureLineRange(in: source, section: section, tag: "NightXpm") {
                if wanted == .night, let nightBlock = section.nightXpm,
                   let dayRange = pictureLineRange(in: source, section: section, tag: nil) {
                    let indent = indentation(of: source.lines[dayRange.lowerBound])
                    let tag = pictureTag(of: source.lines[dayRange.lowerBound]) ?? "Xpm"
                    edits.append((nightRange, []))
                    edits.append((dayRange, render(nightBlock, tag: tag, indent: indent)))
                    dayPictureReplaced = true
                } else {
                    edits.append((nightRange, []))
                }
            }

            // Everything else keeps night in the back half of one palette.
            if section.kind != .point, !dayPictureReplaced {
                let slots = section.colourSlots
                if !slots.night.isEmpty, let block = section.xpm,
                   let extent = pictureLineRange(in: source, section: section, tag: nil) {
                    var palette = Array(block.palette.prefix(slots.day.count))
                    if wanted == .night {
                        let night = block.colours
                        for i in palette.indices where night.indices.contains(slots.day.count + i) {
                            palette[i] = (key: palette[i].key,
                                          colour: night[slots.day.count + i])
                        }
                    }
                    let kept = XpmBlock(width: block.width, height: block.height,
                                        declaredColours: palette.count,
                                        charsPerPixel: block.charsPerPixel,
                                        palette: palette, rows: block.rows)
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
    /// A line or polygon with two colours says nothing about night, so the block grows
    /// from two colours to four. The new pair starts as a copy of the day pair; the pixel
    /// rows are untouched, since they only ever name the first two keys.
    static func addNightColours(in source: TypSource, kind: MapElementKind,
                                code: Int) throws -> String {
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
        guard block.palette.count == 2 else { throw EditError.noPicture(code) }

        let used = Set(block.palette.map(\.key))
        // `3` and `4` are the conventional keys for the night pair; other keys are taken
        // only when those are already used.
        var keys: [String] = []
        for candidate in ["3", "4"] + XpmBlock.keyAlphabet.map(String.init)
        where keys.count < 2 {
            guard !used.contains(candidate), !keys.contains(candidate),
                  candidate.count == max(1, block.charsPerPixel) else { continue }
            keys.append(candidate)
        }
        guard keys.count == 2 else { throw EditError.noPicture(code) }

        var palette = block.palette
        palette.append((key: keys[0], colour: block.palette[0].colour))
        palette.append((key: keys[1], colour: block.palette[1].colour))

        let grown = XpmBlock(width: block.width, height: block.height,
                             declaredColours: palette.count,
                             charsPerPixel: block.charsPerPixel,
                             palette: palette, rows: block.rows)
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
        guard let day = section.dayXpm else { throw EditError.noPicture(code) }
        guard section.nightXpm == nil else {
            throw AddError.alreadyThere(.point, code)
        }
        guard let extent = pictureLineRange(in: source, section: section, tag: "DayXpm") else {
            throw EditError.noPicture(code)
        }

        var lines = source.lines
        let indent = indentation(of: lines[extent.lowerBound])
        var block = [indent + "; The same drawing after dark. Only the colours differ."]
        block.append(contentsOf: render(day, tag: "NightXpm", indent: indent))
        lines.insert(contentsOf: block, at: extent.upperBound)
        return lines.joined(separator: "\n")
    }
}
