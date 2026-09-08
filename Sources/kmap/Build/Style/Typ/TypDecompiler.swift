import Foundation

/// Turns a decoded TYP back into source the mkgmap TYP compiler will accept.
///
/// The output is a reconstruction, not the source the file was compiled from: comments,
/// section order and the letters chosen for a palette are not held in the binary. What
/// survives is everything that governs what the device draws.
enum TypDecompiler {

    /// Whether an element has anything to draw with. One that does not is dropped rather
    /// than given an invented colour: a section with no `Xpm` is refused by the compiler,
    /// and a type with no section is left for the device to draw its own way.
    static func isUsable(_ element: TypBinary.Element) -> Bool {
        if element.dayImage != nil || element.bitmap != nil { return true }
        return element.colours.contains { $0 != nil }
    }

    /// Writes TYP source for a decoded file.
    ///
    /// - Parameter origin: what to name as the source in the header comment.
    static func source(_ typ: TypBinary, origin: String? = nil) -> String {
        var out: [String] = []
        out.append(contentsOf: preamble(typ, origin: origin))
        out.append("")
        out.append(contentsOf: identity(typ))
        out.append("")
        out.append(contentsOf: drawOrder(typ))

        for kind in [MapElementKind.polygon, .line, .point] {
            let elements = typ.elements(kind).filter(isUsable).sorted { $0.code < $1.code }
            guard !elements.isEmpty else { continue }
            out.append("")
            out.append("; " + String(repeating: "-", count: 74))
            out.append("; \(kind.rawValue)s — \(elements.count) section(s)")
            out.append("; " + String(repeating: "-", count: 74))
            for element in elements {
                out.append("")
                out.append(contentsOf: section(element))
            }
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: The parts that are not elements

    private static func preamble(_ typ: TypBinary, origin: String?) -> [String] {
        var out = ["; -*- coding: UTF-8 -*-",
                   "; " + String(repeating: "=", count: 74)]
        if let origin {
            out.append("; Decompiled by kmap from \(origin).")
        } else {
            out.append("; Decompiled by kmap from a compiled TYP.")
        }
        out.append(contentsOf: [
            ";",
            "; This is a reconstruction, not the file its author wrote. A compiled TYP has",
            "; nowhere to keep comments, section order or the letters chosen for a palette,",
            "; so none of that came back. What did come back is everything the device acts",
            "; on: type codes, colours, patterns, icons, widths, label styling and the type",
            "; names in every language the file carried.",
            ";"])

        let inexact = typ.all.filter { !$0.exact }
        let dropped = typ.all.filter { !isUsable($0) }

        if inexact.isEmpty {
            out.append("; Every one of the \(typ.all.count) elements ended exactly where the "
                       + "next one begins,")
            out.append("; which is the check that says the whole file was understood.")
        } else {
            // A section that did not decode cleanly may still be mostly right, so the
            // inexact ones are marked rather than dropped.
            out.append("; \(typ.exactCount) of \(typ.all.count) elements ended exactly where "
                       + "the next one begins. The")
            out.append("; \(inexact.count) that did not are marked NOT FULLY DECODED where "
                       + "they appear below;")
            out.append("; their colours and labels may still be right, but nothing here "
                       + "guarantees it.")
        }

        if !dropped.isEmpty {
            // Named rather than merely counted: a type missing from the output is one the
            // device draws its own way.
            out.append(";")
            out.append("; \(dropped.count) element(s) had nothing readable to draw with and "
                       + "were left out")
            out.append("; entirely. Nothing was invented for them; the device draws those "
                       + "types its own way:")
            for line in wrapCodes(dropped) { out.append("; " + line) }
        }
        out.append("; " + String(repeating: "=", count: 74))
        return out
    }

    /// The dropped codes, a few to a line so a long list stays readable.
    private static func wrapCodes(_ elements: [TypBinary.Element]) -> [String] {
        let names = elements.sorted { ($0.kind.rawValue, $0.code) < ($1.kind.rawValue, $1.code) }
            .map { "\($0.kind.rawValue) \(TypeMeaning.hex($0.code))" }
        var out: [String] = []
        var line = "  "
        for name in names {
            if line.count + name.count + 2 > 74 { out.append(line); line = "  " }
            line += name + "  "
        }
        if line.trimmingCharacters(in: .whitespaces).count > 0 { out.append(line) }
        return out
    }

    private static func identity(_ typ: TypBinary) -> [String] {
        ["[_id]",
         "FID=\(typ.familyID)",
         "ProductCode=\(typ.productID)",
         "CodePage=\(typ.codePage)",
         "[end]"]
    }

    /// The draw order, level by level. A polygon missing from this table is not drawn at
    /// all, so the table is written out whole however long it runs.
    private static func drawOrder(_ typ: TypBinary) -> [String] {
        guard !typ.drawOrder.isEmpty else { return [] }

        // Levels are renumbered from one. The binary marks groups with separators whose
        // count does not map back to source numbering; only the stacking order matters.
        let ordered = Array(Set(typ.drawOrder.map(\.level))).sorted()
        let renumbered = Dictionary(uniqueKeysWithValues:
            ordered.enumerated().map { ($1, $0 + 1) })

        var out = ["[_drawOrder]"]
        var level = 0
        var written = Set<String>()
        for entry in typ.drawOrder.sorted(by: { ($0.level, $0.code) < ($1.level, $1.code) }) {
            let source = renumbered[entry.level] ?? entry.level
            if source != level {
                level = source
                out.append("; --- level \(level) " + String(repeating: "-", count: 50))
            }
            // One record can name the same type twice where two index entries share it;
            // writing it twice is harmless but noisy, and the source form names it once.
            let line = "Type=\(hex(entry.code)),\(source)"
            guard written.insert(line).inserted else { continue }
            out.append(line)
        }
        out.append("[end]")
        out.append("")
        return out
    }

    // MARK: One element

    private static func section(_ element: TypBinary.Element) -> [String] {
        var out = [element.kind.typSection]
        out.append("Type=\(hex(element.code))")
        if !element.exact {
            out.append("; NOT FULLY DECODED — this element did not end where the next one "
                       + "begins.")
            out.append("; What follows is the best reading of it; check it against the "
                       + "device.")
        }
        if let english = element.labels.first(where: { $0.language == 0 })?.text,
           !english.isEmpty {
            out.append("; \(english)")
        }

        switch element.kind {
        case .point:
            if let day = element.dayImage {
                out.append(contentsOf: image(day, tag: "DayXpm"))
            }
            if let night = element.nightImage {
                out.append(contentsOf: image(night, tag: "NightXpm"))
            }
        case .line:
            if element.usesOrientation { out.append("UseOrientation=Y") }
            out.append(contentsOf: pattern(element))
            if let width = element.lineWidth {
                out.append("LineWidth=\(width)")
                // Only a real border: the tag tells the compiler that two colours mean
                // fill and casing rather than day and night.
                if let border = element.borderWidth, border > 0 {
                    out.append("BorderWidth=\(border)")
                }
            }
        case .polygon:
            out.append(contentsOf: pattern(element))
        }

        // Empty labels are written out too: the file is reconstructed, not tidied.
        for label in element.labels {
            out.append("String=\(String(format: "0x%02x", label.language)),\(label.text)")
        }
        // Omitting FontStyle is meaningful — it leaves the style at whatever the device
        // uses — so it is written only where the file actually carried one.
        if let style = element.fontStyle, style != "Default" {
            out.append("FontStyle=\(style)")
        }
        if let colour = element.dayLabelColour { out.append("DayCustomColor=\(colour)") }
        if let colour = element.nightLabelColour { out.append("NightCustomColor=\(colour)") }

        out.append("[end]")
        return out
    }

    /// The `Xpm=` of a line or polygon: solid colours, or a pattern with its palette.
    private static func pattern(_ element: TypBinary.Element) -> [String] {
        // An element with nothing to draw with never reaches here: it is dropped rather
        // than given an invented colour.
        let colours = element.colours.isEmpty ? ["#808080"] : element.colours
        guard let bitmap = element.bitmap else {
            // A solid element lists only the colours it has: in a solid Xpm the compiler
            // counts `none` as a colour and every slot after it reads one out of step.
            let solid = colours.compactMap { $0 }
            var out = ["Xpm=\"0 0 \(solid.count) 0\""]
            for (index, colour) in solid.enumerated() {
                out.append(paletteLine(key: key(index, width: 1), colour: colour))
            }
            return out
        }
        let width = 32
        let height = element.kind == .polygon ? 32 : element.bitmapHeight
        var out = ["Xpm=\"\(width) \(height) \(colours.count) 1\""]
        for (index, colour) in colours.enumerated() {
            out.append(paletteLine(key: key(index, width: 1), colour: colour))
        }
        // Only the first two keys appear in the rows: the pattern is one bit deep, and the
        // device swaps in the night pair itself.
        for row in bitmap {
            out.append("\"" + row.map { key(min($0, colours.count - 1), width: 1) }
                .joined() + "\"")
        }
        return out
    }

    /// A point's image, palette and pixels.
    private static func image(_ image: TypBinary.PointImage, tag: String) -> [String] {
        let colours = image.palette
        guard !colours.isEmpty, image.width > 0, image.height > 0 else { return [] }
        // A palette deeper than the alphabet needs two characters per pixel: Garmin icons
        // run to 256 colours, which no single-character alphabet covers.
        let keyWidth = colours.count <= XpmBlock.keyAlphabet.count ? 1 : 2

        var out = ["\(tag)=\"\(image.width) \(image.height) \(colours.count) \(keyWidth)\""]
        for (index, colour) in colours.enumerated() {
            out.append(paletteLine(key: key(index, width: keyWidth), colour: colour))
        }
        for row in image.pixels {
            out.append("\"" + row.map { key(min($0, colours.count - 1), width: keyWidth) }
                .joined() + "\"")
        }
        return out
    }

    private static func paletteLine(key: String, colour: String?) -> String {
        "\"\(key) c \(colour ?? "none")\""
    }

    /// The palette key for a slot, in a fixed order, so the same TYP decompiles to the
    /// same text every time.
    private static func key(_ index: Int, width: Int) -> String {
        XpmBlock.key(index, width: width)
    }

    /// A type code in the form the compiler reads back as the same type — the one
    /// spelling the rule files, the TYP source and the reassignments share.
    private static func hex(_ code: Int) -> String { TypeMeaning.hex(code) }
}
