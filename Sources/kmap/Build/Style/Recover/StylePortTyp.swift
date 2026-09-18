import Foundation

/// The TYP of a ported look: their drawings on kmap's numbers, over a ground of its own
/// where their style paints none.
extension StylePort {
    /// The ground where their style paints none: kmap's own paper and sea, so the land
    /// is drawn at all. A polygon missing from the draw order is not drawn, and on a
    /// fenix an undrawn land goes black. The night pair is the one topoactive settled
    /// on a fenix: a grey that is unmistakably not water.
    static let paper = "#F4F4F0"
    static let paperAtNight = "#40403D"
    static let seaBlue = "#50A8F8"
    static let seaBlueAtNight = "#004C90"

    /// Whether their style is drawn for night too: most of its painted lines and
    /// polygons carry night colours. The ground supplied for it then carries them as
    /// well, and a day-only style gets a day-only ground, or the two would clash.
    static func paintsNight(_ typ: TypSource) -> Bool {
        let painted = typ.sections.filter { $0.kind != .point && $0.xpm != nil }
        guard !painted.isEmpty else { return false }
        return painted.filter { !$0.colourSlots.night.isEmpty }.count * 2 > painted.count
    }

    /// Below this brightness a fill is dark: mid-grey.
    static let darkBelow = 0.5

    /// Whether their day is dark: a TYP has no night-only mode, so a style made for
    /// the dark carries its dark colours in the day slot, and a paper ground under it
    /// would show as light holes. Most of the polygon fills darker than mid-grey.
    static func drawsDark(_ typ: TypSource) -> Bool {
        let fills = typ.sections.filter { $0.kind == .polygon }
            .compactMap { $0.xpm?.dominantColour ?? $0.xpm?.colours.first ?? nil }
        guard !fills.isEmpty else { return false }
        return fills.filter { brightness(of: $0) < darkBelow }.count * 2 > fills.count
    }

    /// Perceived brightness of `#RRGGBB`, 0 black to 1 white; 1 for anything unreadable.
    static func brightness(of colour: String) -> Double {
        let hex = colour.hasPrefix("#") ? String(colour.dropFirst()) : colour
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return 1 }
        let r = Double((value >> 16) & 0xff), g = Double((value >> 8) & 0xff)
        let b = Double(value & 0xff)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255
    }

    /// The TYP source that carries their drawings on our numbers: each section is
    /// their block verbatim, with the type line rewritten to ours.
    static func typ(from theirs: TypSource, ported: [Ported],
                    familyID: Int?, productID: Int?, codePage: Int?,
                    unstyled: [MapElementKind: Set<Int>] = [:]) -> String {
        var out: [String] = []
        // First, or the compiler reads the file in the platform's charset and gives up
        // on the first Cyrillic label.
        out.append("; -*- coding: UTF-8 -*-")
        out.append("; ported by kmap: the pictures of a borrowed style, on kmap's numbers")
        // Read by the build, ignored by the compiler: this file is written against our
        // numbers, so a number it leaves unpainted is meant to draw nothing.
        out.append("; " + Self.forOurNumbers)
        out.append("[_id]")
        if let familyID { out.append("FID=\(familyID)") }
        if let productID { out.append("ProductCode=\(productID)") }
        if let codePage { out.append("CodePage=\(codePage)") }
        out.append("[end]")
        out.append("")
        // What their map leaves to the receiver stays a rule of ours, unpainted on
        // purpose: the receiver draws it, as it does on theirs.
        for kind in MapElementKind.allCases {
            guard let codes = unstyled[kind], !codes.isEmpty else { continue }
            let listed = codes.sorted().map { String(format: "0x%02x", $0) }.joined(separator: " ")
            out.append("; kmap:unstyled \(kind.rawValue)s \(listed) - their map leaves these"
                       + " to the receiver, which draws them itself")
        }
        if !unstyled.isEmpty { out.append("") }

        var drawOrder: [(code: Int, level: Int)] = []
        let theirOrder = Dictionary(theirs.drawOrder.map { ($0.code, $0.level) },
                                   uniquingKeysWith: { a, _ in a })

        // The ground the map stands on. No OSM way is its source, so no evidence pairs
        // it; both sides get it from mkgmap, and the number is the shared name.
        for (kind, ours, theirsCode) in Self.generatedTypes {
            if let section = theirs.section(kind, theirsCode) {
                out.append("; the build's own \(kind.rawValue) 0x\(String(ours, radix: 16))"
                           + " — drawn as their 0x\(String(theirsCode, radix: 16))")
                out.append(contentsOf: renumbered(theirs.lines[section.lines], to: ours,
                                                  kind: kind))
            } else if kind == .polygon {
                // Their style leaves the ground to the device; ours must not.
                let sea = ours == Self.seaCode
                let night = Self.paintsNight(theirs)
                let dark = Self.drawsDark(theirs)
                let byDay = sea ? (dark ? Self.seaBlueAtNight : Self.seaBlue)
                    : (dark ? Self.paperAtNight : Self.paper)
                out.append("; the build's own polygon 0x\(String(ours, radix: 16))"
                           + " - their style paints none, so kmap's own ground")
                out.append("[_polygon]")
                out.append(String(format: "Type=0x%02x", ours))
                out.append(night ? "Xpm=\"0 0 2 0\"" : "Xpm=\"0 0 1 0\"")
                out.append("\"1 c \(byDay)\"")
                if night { out.append("\"2 c \(sea ? Self.seaBlueAtNight : Self.paperAtNight)\"") }
                out.append("[end]")
            } else {
                continue
            }
            out.append("")
            // The order kmap's own palettes keep. Sharing a level is no order at all:
            // mkgmap writes shapes by descending area, and on a fenix the land loses to
            // the background and the map goes black.
            if kind == .polygon {
                // 0 the background alone, 1 the land and the overview's land, 2 the sea.
                let level = ours == Self.backgroundCode ? 0 : (ours == Self.seaCode ? 2 : 1)
                drawOrder.append((ours, level))
            }
        }
        for port in ported {
            guard let section = theirs.section(port.kind, port.theirs) else { continue }
            out.append("; \(port.meaning) — kmap 0x\(String(port.ours, radix: 16))"
                       + " drawn as their 0x\(String(port.theirs, radix: 16))"
                       + " (\(port.witnesses) seen)")
            out.append(contentsOf: narrowed(renumbered(theirs.lines[section.lines],
                                                       to: port.ours, kind: port.kind),
                                            to: port.width))
            out.append("")
            // Above the ground: their own level, moved up by the two the background and
            // the land keep to themselves.
            if port.kind == .polygon, let level = theirOrder[port.theirs] {
                drawOrder.append((port.ours, level + 3))
            }
        }
        if !drawOrder.isEmpty {
            out.append("[_drawOrder]")
            for entry in drawOrder.sorted(by: { ($0.level, $0.code) < ($1.level, $1.code) }) {
                out.append(String(format: "Type=0x%02x,%d", entry.code, entry.level))
            }
            out.append("[end]")
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The block drawn at a width of its own: only `LineWidth=` changes, and only
    /// downward - a bitmap's thickness is the picture itself and is left alone.
    private static func narrowed(_ block: [String], to width: Int?) -> [String] {
        guard let width else { return block }
        return block.map { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("LineWidth="),
                  let had = Int(text.dropFirst("LineWidth=".count)), width < had
            else { return line }
            return "LineWidth=\(width)"
        }
    }

    /// Their block with the type lines rewritten to our number; a point's low byte is
    /// its subtype, written on a line of its own.
    private static func renumbered(_ block: ArraySlice<String>, to code: Int,
                                   kind: MapElementKind) -> [String] {
        let type = kind == .point ? code >> 8 : code
        let subtype = kind == .point ? code & 0xff : 0
        var out: [String] = []
        var wroteSubtype = false
        for line in block {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Type=") {
                out.append(String(format: "Type=0x%02x", type))
            } else if trimmed.hasPrefix("SubType=") {
                out.append(String(format: "SubType=0x%02x", subtype))
                wroteSubtype = true
            } else {
                out.append(line)
            }
        }
        // A point whose block never said SubType still needs one when ours has a low
        // byte.
        if kind == .point, !wroteSubtype, subtype != 0,
           let at = out.firstIndex(where: { $0.hasPrefix("Type=") }) {
            out.insert(String(format: "SubType=0x%02x", subtype), at: at + 1)
        }
        return out
    }
}
