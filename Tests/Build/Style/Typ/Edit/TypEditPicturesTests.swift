import XCTest

@testable import kmap

final class TypEditPicturesTests: XCTestCase {
    private func parsed(_ text: String) throws -> (TypSource, TypSection) {
        let source = TypSource.parse(text)
        return (source, try XCTUnwrap(source.sections.first))
    }

    /// Highest first, as `keeping` does.
    private func applied(_ edits: [TypEdit.LineEdit], to source: TypSource) -> [String] {
        var lines = source.lines
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            lines.replaceSubrange(edit.range, with: edit.replacement)
        }
        return lines
    }

    // MARK: labelColourEdits

    private let labelled = """
        [_polygon]
        Type=0x13
        Xpm="0 0 1 0"
        "a c #606060"
        DayCustomColor=#111111
        NightCustomColor=#EEEEEE
        [end]
        """

    func testByNightTheLabelTakesItsNightColour() throws {
        let (source, section) = try parsed(labelled)
        let lines = applied(TypEdit.labelColourEdits(section, in: source, keeping: .night), to: source)
        XCTAssertTrue(lines.contains("DayCustomColor=#EEEEEE"))
        XCTAssertFalse(lines.contains("DayCustomColor=#111111"), "the compiler would take the later of 2")
        XCTAssertFalse(lines.contains { $0.hasPrefix("NightCustomColor") })
    }

    func testByDayTheNightLabelColourSimplyGoes() throws {
        let (source, section) = try parsed(labelled)
        let lines = applied(TypEdit.labelColourEdits(section, in: source, keeping: .day), to: source)
        XCTAssertTrue(lines.contains("DayCustomColor=#111111"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("NightCustomColor") })
    }

    func testASectionWithoutALabelColourNeedsNoEdit() throws {
        let (source, section) = try parsed("[_polygon]\nType=0x13\nXpm=\"0 0 1 0\"\n\"a c #606060\"\n[end]")
        XCTAssertTrue(TypEdit.labelColourEdits(section, in: source, keeping: .night).isEmpty)
    }

    // MARK: nightBlockEdits

    private let point = """
        [_point]
        Type=0x2a00
        DayXpm="1 1 1 1"
        "a c #FFFFFF"
        "a"
        NightXpm="1 1 1 1"
        "a c #202020"
        "a"
        [end]
        """

    func testByDayAPointsNightBlockGoes() throws {
        let (source, section) = try parsed(point)
        let night = TypEdit.nightBlockEdits(section, in: source, keeping: .day)
        let lines = applied(night.edits, to: source)
        XCTAssertFalse(night.dayPictureReplaced)
        XCTAssertFalse(lines.contains { $0.hasPrefix("NightXpm") })
        XCTAssertTrue(lines.contains("\"a c #FFFFFF\""))
    }

    func testByNightAPointsNightBlockTakesTheDayOnesPlace() throws {
        let (source, section) = try parsed(point)
        let night = TypEdit.nightBlockEdits(section, in: source, keeping: .night)
        let lines = applied(night.edits, to: source)
        XCTAssertTrue(night.dayPictureReplaced)
        XCTAssertTrue(lines.contains { $0.hasPrefix("DayXpm=") }, "under the day block's own tag")
        XCTAssertFalse(lines.contains { $0.hasPrefix("NightXpm") })
        XCTAssertTrue(lines.contains("\"a c #202020\""))
        XCTAssertFalse(lines.contains("\"a c #FFFFFF\""))
    }

    /// A point drawn by night alone needs a day picture, or mkgmap fails on it.
    func testAPointDrawnByNightAloneGetsItAsItsDayPicture() throws {
        let (source, section) = try parsed(
            "[_point]\nType=0x2a00\nNightXpm=\"1 1 1 1\"\n\"a c #202020\"\n\"a\"\n[end]"
        )
        for theme in [TypEdit.Theme.day, .night] {
            let night = TypEdit.nightBlockEdits(section, in: source, keeping: theme)
            let lines = applied(night.edits, to: source)
            XCTAssertTrue(night.dayPictureReplaced, "\(theme)")
            XCTAssertTrue(lines.contains { $0.hasPrefix("Xpm=") }, "\(theme)")
            XCTAssertFalse(lines.contains { $0.hasPrefix("NightXpm") }, "\(theme)")
        }
    }

    func testASectionWithoutANightBlockNeedsNoEdit() throws {
        let (source, section) = try parsed(labelled)
        let night = TypEdit.nightBlockEdits(section, in: source, keeping: .night)
        XCTAssertTrue(night.edits.isEmpty)
        XCTAssertFalse(night.dayPictureReplaced)
    }

    // MARK: paletteHalfEdit

    private let solid = """
        [_polygon]
        Type=0x13
        Xpm="0 0 2 0"
        "1 c #606060"
        "2 c #2A4040"
        [end]
        """

    func testByDayThePaletteIsCutToItsDayHalf() throws {
        let (source, section) = try parsed(solid)
        let edit = try XCTUnwrap(TypEdit.paletteHalfEdit(section, in: source, keeping: .day))
        let lines = applied([edit], to: source)
        XCTAssertTrue(lines.contains("Xpm=\"0 0 1 0\""))
        XCTAssertTrue(lines.contains("\"1 c #606060\""))
        XCTAssertFalse(lines.contains { $0.contains("#2A4040") })
    }

    func testByNightTheNightColourMovesIntoTheDaySlot() throws {
        let (source, section) = try parsed(solid)
        let edit = try XCTUnwrap(TypEdit.paletteHalfEdit(section, in: source, keeping: .night))
        let lines = applied([edit], to: source)
        XCTAssertTrue(lines.contains("Xpm=\"0 0 1 0\""))
        XCTAssertTrue(lines.contains("\"1 c #2A4040\""), "the day key the rows address, with the night colour")
    }

    func testAPatternsNightKeysBecomeTheDayKeysOfTheirBit() throws {
        let (source, section) = try parsed(
            """
            [_polygon]
            Type=0x14
            Xpm="2 1 4 1"
            "a c #111111"
            "b c #222222"
            "c c #333333"
            "d c #444444"
            "ac"
            [end]
            """
        )
        let edit = try XCTUnwrap(TypEdit.paletteHalfEdit(section, in: source, keeping: .night))
        let lines = applied([edit], to: source)
        XCTAssertTrue(lines.contains("\"aa\""), "c is the night key of a's bit")
        XCTAssertTrue(lines.contains("\"a c #333333\""))
        XCTAssertTrue(lines.contains("\"b c #444444\""))
    }

    func testASectionWithNoNightHalfNeedsNoEdit() throws {
        let (source, section) = try parsed("[_polygon]\nType=0x13\nXpm=\"0 0 1 0\"\n\"a c #606060\"\n[end]")
        XCTAssertNil(TypEdit.paletteHalfEdit(section, in: source, keeping: .night))
    }
}
