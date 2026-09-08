import Foundation

/// One `[_point]` / `[_line]` / `[_polygon]` block of a TYP source file.
///
/// `lines` is the block's exact extent in the file, header and terminator included, so an
/// edit can replace named lines inside that range and leave surrounding comments untouched.
struct TypSection {
    let kind: MapElementKind
    let code: Int

    /// Index range into `TypSource.lines`, from the `[_point]` header through `[end]`.
    let lines: Range<Int>

    /// Comment lines immediately above the header, and those inside the block.
    let comments: [String]

    /// `String=lang,text` entries, in file order.
    let labels: [(language: Int, text: String)]

    let fontStyle: String?
    let dayLabelColour: String?
    let nightLabelColour: String?
    let lineWidth: Int?
    let borderWidth: Int?
    let usesOrientation: Bool

    /// The `Xpm=` of a line or polygon.
    let xpm: XpmBlock?
    /// The `DayXpm=` of a point.
    let dayXpm: XpmBlock?
    /// The `NightXpm=` of a point, where one is given at all.
    let nightXpm: XpmBlock?

    var hex: String { TypeMeaning.hex(code) }

    /// The picture this section draws, whichever tag carries it.
    var picture: XpmBlock? {
        if let dayXpm, !dayXpm.isSolid { return dayXpm }
        if let xpm, !xpm.isSolid { return xpm }
        return nil
    }

    /// The night drawing, or nil where the file states nothing about night. A point holds a
    /// second picture; a pattern holds one set of pixels and two colour pairs — day ink, day
    /// background, night ink, night background — and reads them through the second pair.
    var nightPicture: XpmBlock? {
        if kind == .point { return nightXpm }
        guard let picture, picture.palette.count >= 4 else { return nil }
        let night = picture.colours
        return picture.replacingColour(at: 0, with: night[2])
                      .replacingColour(at: 1, with: night[3])
    }

    /// True where this section carries a pattern whose every pixel is transparent. Third-
    /// party styles store such patterns beside a single named colour. Display only: the
    /// pattern is written back byte for byte as it was read.
    var patternIsBlank: Bool {
        guard let picture, let grid = picture.pixels() else { return false }
        return !grid.contains { $0.contains { $0 != nil } }
    }

    /// Every colour this section names, in declaration order.
    var colours: [String?] {
        (dayXpm ?? xpm)?.colours ?? []
    }

    /// One colour of this section, and what it is for.
    struct ColourSlot: Equatable {
        /// What it paints: the fill, the casing, the ink of a hatch, its background.
        let role: String
        /// Which `Xpm` tag holds it; a point keeps its night picture in a second block.
        let tag: String
        /// Where it sits in that block's palette.
        let index: Int
        let colour: String?
    }

    /// The colours as day and night, paired by role. Two solid colours are day and night;
    /// four are day fill, day casing, night fill, night casing on a cased line and day ink,
    /// day background, night ink, night background on a pattern; a point uses two blocks.
    /// Night comes back empty where the section names day colours only.
    var colourSlots: (day: [ColourSlot], night: [ColourSlot]) {
        if kind == .point {
            let day = (dayXpm?.colours ?? []).enumerated().map {
                ColourSlot(role: t("Colour %d", $0.offset + 1), tag: "DayXpm",
                           index: $0.offset, colour: $0.element)
            }
            let night = (nightXpm?.colours ?? []).enumerated().map {
                ColourSlot(role: t("Colour %d", $0.offset + 1), tag: "NightXpm",
                           index: $0.offset, colour: $0.element)
            }
            return (day, night)
        }

        let block = xpm
        let colours = block?.colours ?? []
        let tag = "Xpm"
        let patterned = block.map { !$0.isSolid } ?? false

        func slot(_ role: String, _ index: Int) -> ColourSlot? {
            guard colours.indices.contains(index) else { return nil }
            return ColourSlot(role: role, tag: tag, index: index, colour: colours[index])
        }

        // Role names are keyed on the element and the colour count, as the TYP compiler
        // documentation keys them.
        let names: (first: String, second: String)
        if patterned {
            names = (t("Ink"), t("Background"))
        } else if (borderWidth ?? 0) > 0 {
            names = (t("Fill"), t("Casing"))
        } else {
            names = (t("Colour"), t("Colour 2"))
        }

        switch colours.count {
        case 4:
            return ([slot(names.first, 0), slot(names.second, 1)].compactMap { $0 },
                    [slot(names.first, 2), slot(names.second, 3)].compactMap { $0 })
        case 2 where patterned || (borderWidth ?? 0) > 0:
            // Both belong to the day pair; the device derives the night pair itself.
            return ([slot(names.first, 0), slot(names.second, 1)].compactMap { $0 }, [])
        case 2:
            return ([slot(t("Colour"), 0)].compactMap { $0 },
                    [slot(t("Colour"), 1)].compactMap { $0 })
        default:
            return (colours.indices.map {
                ColourSlot(role: colours.count > 1 ? t("Colour %d", $0 + 1) : t("Colour"),
                           tag: tag, index: $0, colour: colours[$0])
            }, [])
        }
    }

    /// The single colour standing for this section by day and by night, for a list row with
    /// room for two swatches and not a palette.
    var representativeColours: (day: String?, night: String?) {
        if let picture = picture {
            let dominant = picture.dominantColour
            if kind == .point {
                return (dominant, nightXpm?.dominantColour)
            }
            let slots = colourSlots
            return (dominant, slots.night.first?.colour)
        }
        let slots = colourSlots
        return (slots.day.first?.colour, slots.night.first?.colour)
    }

    /// The label for language 0x00, the device's fallback.
    var englishLabel: String? { label(language: 0x00) }
    /// The label for language 0x19.
    var russianLabel: String? { label(language: 0x19) }

    func label(language: Int) -> String? {
        labels.first { $0.language == language }?.text
    }
}
