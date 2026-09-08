import Foundation

/// Decoding one element of a compiled TYP: its colours, widths and pictures.
extension TypBinary {
    static func decodeElement(_ kind: MapElementKind, _ data: [UInt8], at offset: Int,
                                      length: Int, type: Int, subtype: Int,
                                      codePage: Int) -> Element? {
        guard offset >= 0, offset < data.count else { return nil }

        for candidate in colourCandidates(kind, data[offset]) {
            guard let decoded = try? body(kind, data, at: offset, colourCount: candidate,
                                          type: type, subtype: subtype, codePage: codePage,
                                          exact: true) else { continue }
            if decoded.used == length { return decoded.element }
        }
        // Nothing matched the stored length: keep the first candidate's reading, flagged
        // inexact, rather than dropping a section the index lists.
        if let first = colourCandidates(kind, data[offset]).first,
           let fallback = try? body(kind, data, at: offset, colourCount: first,
                                    type: type, subtype: subtype, codePage: codePage,
                                    exact: false) {
            return fallback.element
        }
        // Even the fallback threw: the element uses an encoding this reader refuses. It is
        // kept empty and inexact, since the index still lists it.
        return Element(kind: kind, type: type, subtype: subtype, colours: [],
                       bitmap: nil, bitmapHeight: 0, dayImage: nil, nightImage: nil,
                       labels: [], fontStyle: nil, dayLabelColour: nil,
                       nightLabelColour: nil, lineWidth: nil, borderWidth: nil,
                       usesOrientation: false, exact: false)
    }

    /// Possible colour counts for an element's scheme, most likely first. Per
    /// `ColourInfo.getColourScheme`: bit 3 marks a bitmap, bit 0 four colours rather than
    /// two, bits 1 and 2 which slots are transparent. Scheme 7 with no bitmap is two solid.
    private static func colourCandidates(_ kind: MapElementKind, _ first: UInt8) -> [Int] {
        if kind == .point { return [0] }
        let scheme = Int(first) & 7
        let hasBitmap = kind == .line ? ((Int(first) >> 3) & 7) > 0 : (Int(first) & 8) != 0
        if hasBitmap { return (scheme & 1) != 0 ? [4] : [2] }
        if (scheme & 1) != 0 { return [4] }
        if scheme == 7 { return [2, 4] }
        return kind == .line ? [2, 1] : [1, 2]
    }

    /// Which slots are transparent, in day-ink, day-background, night-ink, night-background
    /// order. A transparent slot is not stored.
    private static func transparency(scheme: Int, hasBitmap: Bool, count: Int) -> [Bool] {
        if !hasBitmap, scheme == 7, count == 2 { return [false, false] }
        switch count {
        case 4: return [false, (scheme & 2) != 0, false, (scheme & 4) != 0]
        case 2: return [false, (scheme & 2) != 0]
        default: return Array(repeating: false, count: count)
        }
    }

    private struct Decoded {
        let element: Element
        let used: Int
    }

    private static func body(_ kind: MapElementKind, _ data: [UInt8], at offset: Int,
                             colourCount: Int, type: Int, subtype: Int, codePage: Int,
                             exact: Bool) throws -> Decoded {
        switch kind {
        case .point:
            return try point(data, at: offset, type: type, subtype: subtype,
                             codePage: codePage, exact: exact)
        case .polygon:
            return try polygon(data, at: offset, colourCount: colourCount, type: type,
                               subtype: subtype, codePage: codePage, exact: exact)
        case .line:
            return try line(data, at: offset, colourCount: colourCount, type: type,
                            subtype: subtype, codePage: codePage, exact: exact)
        }
    }

    private static func polygon(_ data: [UInt8], at offset: Int, colourCount: Int,
                                type: Int, subtype: Int, codePage: Int,
                                exact: Bool) throws -> Decoded {
        var r = Cursor(data, at: offset)
        let b0 = Int(r.u1())
        let scheme = b0 & 7
        let hasBitmap = (b0 & 8) != 0

        let colours = try r.colours(transparency(scheme: scheme, hasBitmap: hasBitmap,
                                                 count: colourCount))
        let bitmap = hasBitmap ? try r.bitmap(width: 32, height: 32, bitsPerPixel: 1) : nil

        var labels: [(language: Int, text: String)] = []
        if b0 & 0x10 != 0 { labels = decodeLabels(try r.labelBlock(), codePage: codePage) }
        var font: FontInfo = .none
        if b0 & 0x20 != 0 { font = try r.fontInfo() }
        if b0 & 0x40 != 0 { _ = try r.raw(colours.compactMap { $0 }.count) }
        if b0 & 0x80 != 0 { _ = try r.raw(4) }

        return Decoded(element: Element(
            kind: .polygon, type: type, subtype: subtype, colours: colours,
            bitmap: bitmap, bitmapHeight: hasBitmap ? 32 : 0,
            dayImage: nil, nightImage: nil, labels: labels,
            fontStyle: font.style, dayLabelColour: font.day, nightLabelColour: font.night,
            lineWidth: nil, borderWidth: nil, usesOrientation: false, exact: exact),
            used: r.position - offset)
    }

    private static func line(_ data: [UInt8], at offset: Int, colourCount: Int,
                             type: Int, subtype: Int, codePage: Int,
                             exact: Bool) throws -> Decoded {
        var r = Cursor(data, at: offset)
        let b0 = Int(r.u1())
        let flags = Int(r.u1())
        guard b0 & 0x80 == 0, flags & 0xE8 == 0 else { throw ReadError.truncated }

        let scheme = b0 & 7
        let height = (b0 >> 3) & 7
        let hasBitmap = height > 0

        let colours = try r.colours(transparency(scheme: scheme, hasBitmap: hasBitmap,
                                                 count: colourCount))
        var bitmap: [[Int]]?
        var lineWidth: Int?
        var borderWidth: Int?

        if hasBitmap {
            bitmap = try r.bitmap(width: 32, height: height, bitsPerPixel: 1)
            // Garmin-only, seen solely on the extended trail types: 32 further bytes after
            // the pattern. Consumed so the element ends where it should.
            if b0 & 0x40 != 0 { _ = try r.raw(32) }
        } else {
            let width = Int(r.u1())
            lineWidth = width
            if (scheme & 0xFE) != 6 {
                let total = Int(r.u1())
                borderWidth = (total - width) / 2
            } else {
                borderWidth = 0
            }
        }

        var labels: [(language: Int, text: String)] = []
        if flags & 1 != 0 { labels = decodeLabels(try r.labelBlock(), codePage: codePage) }
        var font: FontInfo = .none
        if flags & 4 != 0 { font = try r.fontInfo() }
        if !hasBitmap, b0 & 0x40 != 0 { _ = try r.raw(colours.compactMap { $0 }.count) }
        if flags & 0x10 != 0 { _ = try r.raw(2) }

        return Decoded(element: Element(
            kind: .line, type: type, subtype: subtype, colours: colours,
            bitmap: bitmap, bitmapHeight: height,
            dayImage: nil, nightImage: nil, labels: labels,
            fontStyle: font.style, dayLabelColour: font.day, nightLabelColour: font.night,
            lineWidth: lineWidth, borderWidth: borderWidth,
            // The flag is set when orientation is *not* used, so the sense is inverted.
            usesOrientation: (flags & 2) == 0, exact: exact),
            used: r.position - offset)
    }

    private static func point(_ data: [UInt8], at offset: Int, type: Int, subtype: Int,
                              codePage: Int, exact: Bool) throws -> Decoded {
        var r = Cursor(data, at: offset)
        let flags = Int(r.u1())
        let width = Int(r.u1())
        let height = Int(r.u1())

        let day = try r.pointImage(width: width, height: height)
        let night = flags & 2 != 0 ? try r.pointImage(width: width, height: height) : nil

        var labels: [(language: Int, text: String)] = []
        if flags & 4 != 0 { labels = decodeLabels(try r.labelBlock(), codePage: codePage) }
        var font: FontInfo = .none
        if flags & 8 != 0 { font = try r.fontInfo() }

        return Decoded(element: Element(
            kind: .point, type: type, subtype: subtype, colours: [],
            bitmap: nil, bitmapHeight: 0,
            dayImage: day, nightImage: night, labels: labels,
            fontStyle: font.style, dayLabelColour: font.day, nightLabelColour: font.night,
            lineWidth: nil, borderWidth: nil, usesOrientation: false, exact: exact),
            used: r.position - offset)
    }
}
