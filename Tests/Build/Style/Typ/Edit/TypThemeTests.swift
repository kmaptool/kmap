import XCTest

@testable import kmap

/// Packing one of a TYP's two drawings and leaving the other out.
///
/// Night is not a type code and not a section: it is the back half of a palette, a second
/// picture on a point, and `NightCustomColor` on a label.
final class TypThemeTests: XCTestCase {
    private let source = """
        [_polygon]
        Type=0x27
        ; the land, day then night
        Xpm="0 0 2 0"
        "1 c #F4F4F0"
        "2 c #40403D"
        String=0x00,Land
        [end]

        [_polygon]
        Type=0x16
        Xpm="4 2 4 1"
        "1 c #6AA84F"
        "2 c none"
        "3 c #2E4A22"
        "4 c none"
        "1221"
        "2112"
        [end]

        [_line]
        Type=0x02
        BorderWidth=1
        Xpm="0 0 4 0"
        "1 c #E8A070"
        "2 c #804000"
        "3 c #402000"
        "4 c #201000"
        [end]

        [_point]
        Type=0x2f01
        DayXpm="2 1 2 1"
        "! c #000000"
        "  c none"
        "! "
        NightXpm="2 1 2 1"
        "! c #FFFFFF"
        "  c none"
        "! "
        DayCustomColor=#101010
        NightCustomColor=#F0F0F0
        [end]
        """

    func testDayOnlyLeavesNothingOfTheNight() {
        let out = TypEdit.keeping(.day, in: source)
        XCTAssertEqual(out.elements, 4, "every section here says something about night")
        XCTAssertFalse(out.text.contains("#40403D"), "the land's night fill")
        XCTAssertFalse(out.text.contains("#2E4A22"), "the pattern's night ink")
        XCTAssertFalse(out.text.contains("#402000"), "the line's night fill")
        XCTAssertFalse(out.text.contains("NightXpm"), "the point's night picture")
        XCTAssertFalse(out.text.contains("NightCustomColor"), "and its night label colour")

        // The header must count the colours that remain.
        XCTAssertTrue(out.text.contains("Xpm=\"0 0 1 0\""), "the land is one colour now")
        XCTAssertTrue(out.text.contains("Xpm=\"4 2 2 1\""), "the pattern keeps its day pair")
        XCTAssertTrue(out.text.contains("#F4F4F0"))
        XCTAssertTrue(out.text.contains("#E8A070"))
        XCTAssertTrue(out.text.contains("DayCustomColor=#101010"))
    }

    func testNightOnlyMovesTheNightColoursIntoTheDaySlots() {
        let out = TypEdit.keeping(.night, in: source)
        XCTAssertTrue(out.text.contains("#40403D"), "the land is drawn in its night fill")
        XCTAssertFalse(out.text.contains("#F4F4F0"), "and no longer in its day one")
        XCTAssertTrue(out.text.contains("#2E4A22"))
        XCTAssertTrue(out.text.contains("#402000"))
        XCTAssertFalse(out.text.contains("NightXpm"), "the point's night picture became its day one")
        XCTAssertTrue(out.text.contains("#FFFFFF"))
        XCTAssertFalse(out.text.contains("#000000"))
        XCTAssertTrue(out.text.contains("DayCustomColor=#F0F0F0"))
        XCTAssertFalse(out.text.contains("#101010"))
    }

    /// Night colours take over the day keys, so the pixel rows, which address colours by
    /// key, keep pointing at entries that exist.
    func testAPatternStillPaintsItsPixelsAfterTheSwap() {
        let out = TypEdit.keeping(.night, in: source)
        XCTAssertTrue(out.text.contains("\"1221\""), "the rows are untouched")
        XCTAssertTrue(out.text.contains("\"1 c #2E4A22\""), "and key 1 now holds the night ink")
    }

    func testKeepingBothIsTheFileItself() {
        let out = TypEdit.keeping(.all, in: source)
        XCTAssertEqual(out.text, source)
        XCTAssertEqual(out.elements, 0)
    }

    /// Comments and everything not part of a night drawing come through unchanged.
    func testEveryOtherLineArrivesUntouched() {
        let out = TypEdit.keeping(.day, in: source)
        XCTAssertTrue(out.text.contains("; the land, day then night"))
        XCTAssertTrue(out.text.contains("String=0x00,Land"))
        XCTAssertTrue(out.text.contains("BorderWidth=1"))
    }

    /// mkgmap's own test file: a solid fill clear by night keeps its day colour, and a
    /// pattern drawn with a night key draws it with the day key of its place.
    func testThemesLeaveEveryPictureOneMkgmapTakes() {
        let solid = "[_polygon]\nType=0x02\nXpm=\"0 0 2 1\"\n\"* c #990099\"\n\"  c None\"\n[end]"
        XCTAssertEqual(
            TypSource.parse(TypEdit.keeping(.night, in: solid).text).section(.polygon, 0x02)?.colours,
            ["#990099"]
        )
        let pattern = """
            [_polygon]
            Type=0x03
            Xpm="2 1 4 1"
            "a c #FF0000"
            "b c #00FF00"
            "c c #0000FF"
            "d c #FFFFFF"
            "ad"
            [end]
            """
        let day = TypSource.parse(TypEdit.keeping(.day, in: pattern).text).section(.polygon, 0x03)?.xpm
        XCTAssertEqual(day?.rows, ["ab"])
        XCTAssertEqual(day?.palette.map(\.key), ["a", "b"])
    }

    /// A solid clear by day shows the colour mkgmap shows; a pattern whose night ink is
    /// clear is drawn as mkgmap swaps it, by night and in the rows a day keeps.
    func testThemesFollowMkgmapsSwaps() {
        let solid = "[_polygon]\nType=0x02\nXpm=\"0 0 2 0\"\n\"a c None\"\n\"b c #00FF00\"\n[end]"
        XCTAssertEqual(
            TypSource.parse(TypEdit.keeping(.day, in: solid).text).section(.polygon, 0x02)?.colours,
            ["#00FF00"]
        )
        func pattern(_ rows: String) -> String {
            """
            [_polygon]
            Type=0x03
            Xpm="4 1 4 1"
            "a c #FF0000"
            "b c #00FF00"
            "c c none"
            "d c #0000FF"
            "\(rows)"
            [end]
            """
        }
        let night = TypSource.parse(TypEdit.keeping(.night, in: pattern("aabb")).text).section(.polygon, 0x03)?.xpm
        XCTAssertEqual(night?.colours, ["#0000FF", nil])
        XCTAssertEqual(night?.rows, ["aabb"])
        let day = TypSource.parse(TypEdit.keeping(.day, in: pattern("acbd")).text).section(.polygon, 0x03)?.xpm
        XCTAssertEqual(day?.rows, ["abba"])
    }

    /// mkgmap puts a clear ink behind its pair's other colour by day and by night apart,
    /// and draws by bits: the themes follow each pair's order.
    func testThemesFollowBothOfMkgmapsSwaps() {
        func pattern(_ dayInk: String, _ nightInk: String, rows: String) -> String {
            """
            [_polygon]
            Type=0x03
            Xpm="4 1 4 1"
            "a c \(dayInk)"
            "b c #00FF00"
            "c c \(nightInk)"
            "d c #0000FF"
            "\(rows)"
            [end]
            """
        }
        func kept(_ theme: TypEdit.Theme, _ text: String) -> XpmBlock? {
            TypSource.parse(TypEdit.keeping(theme, in: text).text).section(.polygon, 0x03)?.xpm
        }
        // Both inks clear.
        XCTAssertEqual(kept(.night, pattern("none", "none", rows: "aabb"))?.colours, [nil, "#0000FF"])
        XCTAssertEqual(kept(.day, pattern("none", "none", rows: "acbd"))?.rows, ["aabb"])
        // The day ink clear, the night one not.
        XCTAssertEqual(kept(.night, pattern("none", "#FF0000", rows: "aabb"))?.colours, ["#0000FF", "#FF0000"])
    }

    /// 2 night entries of 1 key: mkgmap indexes after its swap, so the later in bit order
    /// is what the key draws. Here `c` is clear by night.
    func testANightKeyGivenTwiceDrawsAsMkgmapIndexesIt() {
        let text = """
            [_polygon]
            Type=0x03
            Xpm="3 1 4 1"
            "a c none"
            "b c #FF0000"
            "c c none"
            "c c #FF0000"
            "abc"
            [end]
            """
        let night = TypSource.parse(TypEdit.keeping(.night, in: text).text).section(.polygon, 0x03)?.xpm
        XCTAssertEqual(night?.colours, [nil, "#FF0000"])
        XCTAssertEqual(night?.rows, ["aba"])
    }
}
