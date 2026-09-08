import Foundation
@testable import kmap

/// A TYP source carrying the shapes a real one has: comments above and inside sections, a
/// semicolon used as a palette key, a transparent slot in a pattern, a two-colour polygon,
/// a cased line, a bitmap line, a 20×20 icon, labels in two languages and one with no
/// text, and a draw order that accounts for every polygon.
enum TypFixture {

    /// Section counts in `source`, so a test can assert against them by name.
    static let polygonCount = 3
    static let lineCount = 3
    static let pointCount = 2

    /// The type whose icon is a full-size badge.
    static let iconCode = 0x2a00
    static let iconWidth = 20
    static let iconColours = 23

    static let source: String = {
        var out = """
        ; -*- coding: UTF-8 -*-
        ; ============================================================================
        ; A fixture standing in for a real TYP.  The comments matter: they are what a
        ; hand-written TYP carries and what the binary format has nowhere to put, so
        ; every edit is checked against their survival.
        ; ============================================================================

        [_id]
        FID=6324
        ProductCode=1
        CodePage=1252
        [end]

        [_drawOrder]
        ; --- level 1 --------------------------------------------------------------
        Type=0x4b,1
        ; --- level 2 --------------------------------------------------------------
        Type=0x16,2
        Type=0x51,2
        [end]

        ; --------------------------------------------------------------------------
        ; polygons
        ; --------------------------------------------------------------------------

        ; Map background.  The highest code in its level, so it is painted first.
        [_polygon]
        Type=0x4b
        Xpm="0 0 1 0"
        "a c #F4F4F0"
        String=0x00,Background
        [end]

        ; Nature reserve.  Measured out of a reference product, family 9469.
        ; Two colours: the first is day, the second night.
        [_polygon]
        Type=0x16
        Xpm="0 0 2 0"
        "a c #A0D070"
        "b c #204020"
        String=0x00,Nature reserve
        String=0x19,Заповедник
        [end]

        ; Scree.  A hatch rather than a flood, so the ground shows through between the
        ; strokes -- which is what the transparent second colour is for.
        [_polygon]
        Type=0x51
        Xpm="32 32 4 1"

        """
        out += pattern32()
        out += """
        String=0x00,Scree
        [end]

        ; --------------------------------------------------------------------------
        ; lines
        ; --------------------------------------------------------------------------

        ; A cased road: fill and casing, day and night.
        [_line]
        Type=0x07
        Xpm="0 0 4 0"
        "a c #D0D4D0"
        "b c #404040"
        "c c #B0B4B0"
        "d c #686868"
        LineWidth=1
        BorderWidth=1
        String=0x00,Service road
        String=0x19,Проезд
        [end]

        ; A contour, labelled, with no font size forced -- omitting FontStyle leaves the
        ; device to choose, which is a different instruction from naming the default.
        [_line]
        Type=0x20
        Xpm="0 0 1 0"
        "a c #A89028"
        LineWidth=1
        String=0x00,Contour
        DayCustomColor=#685820
        [end]

        ; A cutline: a dashed band, the dashes on the two rows offset so it reads as a
        ; break in the trees rather than as a track.
        [_line]
        Type=0x23
        UseOrientation=Y
        Xpm="32 2 4 1"
        "! c #789400"
        ". c none"
        "3 c #789400"
        "4 c none"
        "....!!......!!......!!......!!.."
        "!!......!!......!!......!!......"
        String=0x00,Cutline
        String=0x19,Просека
        FontStyle=NoLabel
        [end]

        ; --------------------------------------------------------------------------
        ; points
        ; --------------------------------------------------------------------------

        ; Restaurant.  A full-size badge, and its palette uses a semicolon as one of its
        ; keys -- a comment-stripper that does not check for quotes truncates it here.
        [_point]
        Type=0x2a00

        """
        out += icon20()
        out += """
        String=0x00,Restaurant
        String=0x19,Ресторан
        [end]

        ; A label anchor: drawn as a small mark, and carrying an empty entry for one
        ; language, which is a thing real files do and a reconstruction must not tidy.
        [_point]
        Type=0x6511
        DayXpm="2 2 2 1"
        "! c #1878C8"
        ". c none"
        "!."
        ".!"
        String=0x00,Spring
        String=0x01,
        [end]

        """
        return out
    }()

    /// A 32×32 hatch: four colours, the second and fourth transparent so the ground shows
    /// through, and the ink on a diagonal.
    private static func pattern32() -> String {
        var out = "\"! c #C0B090\"\n\". c none\"\n\"3 c #807050\"\n\"4 c none\"\n"
        for y in 0..<32 {
            out += "\"" + (0..<32).map { ($0 + y) % 8 == 0 ? "!" : "." }.joined() + "\"\n"
        }
        return out
    }

    /// A 20×20 badge with a 23-colour palette, one key of which is a semicolon.
    private static func icon20() -> String {
        let keys = Array("abcdefghijklmnopqrstuv;")
        var out = "DayXpm=\"20 20 23 1\"\n"
        for (index, key) in keys.enumerated() {
            out += "\"\(key) c #\(String(format: "%02X%02X%02X", 0xF8, index * 11 % 256, 0x30))\"\n"
        }
        for y in 0..<20 {
            out += "\"" + (0..<20).map { x -> String in
                // A border in the first colour, the rest cycling through the palette so
                // every entry is referenced by something.
                let onEdge = x == 0 || y == 0 || x == 19 || y == 19
                return String(onEdge ? keys[0] : keys[(x + y * 3) % keys.count])
            }.joined() + "\"\n"
        }
        return out
    }
}
