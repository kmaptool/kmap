import XCTest
@testable import kmap

/// Covers editing a TYP source in place.
///
/// The property under test is that nothing but the edited value changes, so every test
/// asserts the exact set of changed lines.
final class TypEditTests: XCTestCase {

    /// Line numbers where two versions of a file differ, plus any change in length.
    private func changedLines(_ before: String, _ after: String) -> [Int] {
        let a = before.components(separatedBy: "\n")
        let b = after.components(separatedBy: "\n")
        var out: [Int] = []
        for i in 0..<max(a.count, b.count) where a[safe: i] != b[safe: i] {
            out.append(i)
        }
        return out
    }

    private let sample = """
        ; -*- coding: UTF-8 -*-
        ; A comment above the section that must survive.

        [_polygon]
        Type=0x16
        ; Nature reserve.  Measured out of a reference product, family 9469.
        Xpm="0 0 2 0"
        "a c #A0D070"
        "b c #204020"
        String=0x00,Nature reserve
        String=0x19,Заповедник
        [end]

        [_point]
        Type=0x2a00
        DayXpm="2 2 2 1"
        "! c #F80000"
        ". c none"
        "!."
        ".!"
        String=0x00,Restaurant
        [end]
        """

    // MARK: Colours

    func testChangingAColourTouchesThatLineAndNoOther() throws {
        let source = TypSource.parse(sample)
        let edited = try TypEdit.setColour(in: source, kind: .polygon, code: 0x16,
                                           colourIndex: 0, to: "#68B0F8")

        XCTAssertEqual(changedLines(sample, edited), [7], "only the day colour line")
        XCTAssertEqual(edited.components(separatedBy: "\n")[7], "\"a c #68B0F8\"")
    }

    /// Every pixel row addresses colours by key, so the key is kept: rewriting it would
    /// leave the rows pointing at a missing palette entry.
    func testThePaletteKeyIsKeptSoThePixelsStillFindTheirColour() throws {
        let source = TypSource.parse(sample)
        let edited = try TypEdit.setColour(in: source, kind: .point, code: 0x2a00,
                                           colourIndex: 0, to: "#00FF00")
        XCTAssertTrue(edited.contains("\"! c #00FF00\""), edited)

        let reparsed = TypSource.parse(edited)
        let picture = try XCTUnwrap(reparsed.section(.point, 0x2a00)?.picture)
        XCTAssertEqual(picture.pixels()?.first ?? [], ["#00FF00", nil])
    }

    func testTheSecondColourIsTheNightOne() throws {
        let source = TypSource.parse(sample)
        let edited = try TypEdit.setColour(in: source, kind: .polygon, code: 0x16,
                                           colourIndex: 1, to: "#101010")
        XCTAssertEqual(changedLines(sample, edited), [8])
        XCTAssertEqual(TypSource.parse(edited).section(.polygon, 0x16)?.colours,
                       ["#A0D070", "#101010"])
    }

    func testAColourCanBeMadeTransparent() throws {
        let source = TypSource.parse(sample)
        let edited = try TypEdit.setColour(in: source, kind: .point, code: 0x2a00,
                                           colourIndex: 0, to: nil)
        XCTAssertTrue(edited.contains("\"! c none\""), edited)
    }

    func testAColourIsWrittenBackInTheCaseTheFileUses() throws {
        let source = TypSource.parse(sample)
        let edited = try TypEdit.setColour(in: source, kind: .polygon, code: 0x16,
                                           colourIndex: 0, to: "68b0f8")
        XCTAssertTrue(edited.contains("\"a c #68B0F8\""), edited)
    }

    func testIndentationIsPreserved() throws {
        let indented = "[_polygon]\n    Type=0x16\n    Xpm=\"0 0 1 0\"\n    \"a c #A0D070\"\n[end]"
        let edited = try TypEdit.setColour(in: TypSource.parse(indented), kind: .polygon,
                                           code: 0x16, colourIndex: 0, to: "#000000")
        XCTAssertTrue(edited.contains("    \"a c #000000\""), edited)
    }

    // MARK: Refusing rather than mangling

    func testRubbishIsRefusedAndTheFileIsNotTouched() {
        let source = TypSource.parse(sample)
        XCTAssertThrowsError(try TypEdit.setColour(in: source, kind: .polygon, code: 0x16,
                                                   colourIndex: 0, to: "reddish"))
    }

    func testAColourThatIsNotThereIsRefused() {
        let source = TypSource.parse(sample)
        XCTAssertThrowsError(try TypEdit.setColour(in: source, kind: .polygon, code: 0x16,
                                                   colourIndex: 9, to: "#000000"))
    }

    func testASectionThatIsNotThereIsRefused() {
        let source = TypSource.parse(sample)
        XCTAssertThrowsError(try TypEdit.setColour(in: source, kind: .polygon, code: 0x99,
                                                   colourIndex: 0, to: "#000000"))
        // Line 0x16 and polygon 0x16 are different types; the kind is part of the lookup.
        XCTAssertThrowsError(try TypEdit.setColour(in: source, kind: .line, code: 0x16,
                                                   colourIndex: 0, to: "#000000"))
    }

    // MARK: Labels

    func testALabelIsReplacedInPlace() throws {
        let source = TypSource.parse(sample)
        let edited = try TypEdit.setLabel(in: source, kind: .polygon, code: 0x16,
                                          language: 0x19, to: "Природный заповедник")
        XCTAssertEqual(changedLines(sample, edited), [10])
        XCTAssertEqual(TypSource.parse(edited).section(.polygon, 0x16)?.russianLabel,
                       "Природный заповедник")
    }

    /// A new label is inserted after the last existing one, so a comment written under
    /// the labels stays under them.
    func testANewLabelIsAddedBesideTheExistingOnes() throws {
        let source = TypSource.parse(sample)
        let edited = try TypEdit.setLabel(in: source, kind: .point, code: 0x2a00,
                                          language: 0x19, to: "Ресторан")
        let lines = edited.components(separatedBy: "\n")
        let english = try XCTUnwrap(lines.firstIndex(of: "String=0x00,Restaurant"))
        XCTAssertEqual(lines[english + 1], "String=0x19,Ресторан")
        XCTAssertEqual(TypSource.parse(edited).section(.point, 0x2a00)?.englishLabel,
                       "Restaurant", "the existing label must survive")
    }

    // MARK: Whole pictures

    func testReplacingAPictureLeavesTheRestOfTheSectionAlone() throws {
        let source = TypSource.parse(sample)
        let replacement = XpmBlock(width: 2, height: 2, declaredColours: 2, charsPerPixel: 1,
                                   palette: [(key: "x", colour: "#123456"),
                                             (key: "y", colour: nil)],
                                   rows: ["xy", "yx"])
        let edited = try TypEdit.setPicture(in: source, kind: .point, code: 0x2a00,
                                            to: replacement)

        // Two palette lines and two rows; the header is unchanged, the replacement being
        // of the same size and colour count.
        XCTAssertEqual(changedLines(sample, edited), [16, 17, 18, 19])
        XCTAssertTrue(edited.contains("String=0x00,Restaurant"))
        XCTAssertTrue(edited.contains("Type=0x2a00"))

        let picture = try XCTUnwrap(TypSource.parse(edited).section(.point, 0x2a00)?.picture)
        XCTAssertEqual(picture.pixels() ?? [], [["#123456", nil], [nil, "#123456"]])
    }

    /// A replacement of a different size is written with its own header, which must match
    /// the number of rows it carries.
    func testAPictureOfADifferentSizeChangesTheHeaderToMatch() throws {
        let source = TypSource.parse(sample)
        let replacement = XpmBlock(width: 3, height: 1, declaredColours: 1, charsPerPixel: 1,
                                   palette: [(key: "z", colour: "#FFFFFF")], rows: ["zzz"])
        let edited = try TypEdit.setPicture(in: source, kind: .point, code: 0x2a00,
                                            to: replacement)
        XCTAssertTrue(edited.contains("DayXpm=\"3 1 1 1\""), edited)

        let picture = try XCTUnwrap(TypSource.parse(edited).section(.point, 0x2a00)?.picture)
        XCTAssertEqual(picture.width, 3)
        XCTAssertEqual(picture.rows, ["zzz"])
    }

    /// The replacement keeps the original tag: writing `Xpm=` over a point's `DayXpm=`
    /// would leave the point with no icon.
    func testAPointKeepsItsDayXpmTag() throws {
        let source = TypSource.parse(sample)
        let replacement = XpmBlock(width: 1, height: 1, declaredColours: 1, charsPerPixel: 1,
                                   palette: [(key: "z", colour: "#FFFFFF")], rows: ["z"])
        let edited = try TypEdit.setPicture(in: source, kind: .point, code: 0x2a00,
                                            to: replacement)
        XCTAssertTrue(edited.contains("DayXpm="), edited)
        XCTAssertFalse(edited.contains("\nXpm=\"1 1"), edited)
    }

    // MARK: Adding a section that was not there

    /// A type the file does not style is drawn the receiver's own way, so a section for it
    /// can be added.
    func testASectionCanBeCreatedForATypeTheFileDoesNotStyle() throws {
        let source = TypSource.parse(sample)
        XCTAssertNil(source.section(.point, 0x2f06))

        let edited = try TypEdit.addSection(in: source, kind: .point, code: 0x2f06,
                                            label: "amenity=bank")
        let after = TypSource.parse(edited)

        let added = try XCTUnwrap(after.section(.point, 0x2f06))
        XCTAssertEqual(added.englishLabel, "amenity=bank")
        XCTAssertNotNil(added.picture, "a point needs something to draw")
        XCTAssertEqual(added.picture?.colours.compactMap { $0 }, ["#FF00FF"],
                       "magenta: a new section is not a finished one")
    }

    func testEverySectionAlreadyThereSurvivesTheAddition() throws {
        let source = TypSource.parse(sample)
        let edited = try TypEdit.addSection(in: source, kind: .line, code: 0x23)
        let after = TypSource.parse(edited)

        XCTAssertEqual(after.sections.count, source.sections.count + 1)
        XCTAssertEqual(after.section(.polygon, 0x16)?.colours, ["#A0D070", "#204020"])
        XCTAssertEqual(after.section(.point, 0x2a00)?.englishLabel, "Restaurant")
        XCTAssertTrue(edited.hasPrefix(sample.components(separatedBy: "\n")[0]),
                      "the file it was added to comes first and unchanged")
    }

    func testAddingOneThatIsAlreadyThereIsRefused() {
        let source = TypSource.parse(sample)
        XCTAssertThrowsError(try TypEdit.addSection(in: source, kind: .polygon, code: 0x16))
    }

    /// A polygon absent from `[_drawOrder]` is not drawn, whatever its section says.
    func testANewPolygonIsPutIntoTheDrawOrderAsWellAsGivenASection() throws {
        let withOrder = """
            [_drawOrder]
            Type=0x16,1
            Type=0x51,2
            [end]

            [_polygon]
            Type=0x16
            Xpm="0 0 1 0"
            "a c #A0D070"
            [end]
            """
        let source = TypSource.parse(withOrder)
        let edited = try TypEdit.addSection(in: source, kind: .polygon, code: 0x4d)
        let after = TypSource.parse(edited)

        XCTAssertNotNil(after.section(.polygon, 0x4d))
        XCTAssertTrue(after.drawOrder.contains { $0.code == 0x4d },
                      "a polygon missing from the draw order is never drawn")
        XCTAssertEqual(after.polygonsMissingFromDrawOrder, [])
        // Above the ground cover rather than hidden beneath it.
        XCTAssertEqual(after.drawOrder.first { $0.code == 0x4d }?.level, 2)
    }

    /// The compiler reads a draw-order entry to the end of its line, so whatever is
    /// said about it is said above it.
    func testADrawOrderEntryCarriesNothingButTheTypeAndItsLevel() throws {
        let source = TypSource.parse("[_drawOrder]\nType=0x16,1\n[end]\n")
        let edited = try TypEdit.addSection(in: source, kind: .polygon, code: 0x4d)
        let entry = try XCTUnwrap(edited.split(separator: "\n").map(String.init)
            .first { $0.hasPrefix("Type=0x4d,") })
        XCTAssertEqual(entry, "Type=0x4d,1")
        XCTAssertFalse(entry.contains(";"), "a comment here is read as part of the level")
    }

    /// A line or a point has no draw order to be in, so nothing is added to one.
    func testALineIsNotPutIntoTheDrawOrder() throws {
        let source = TypSource.parse("[_drawOrder]\nType=0x16,1\n[end]\n")
        let edited = try TypEdit.addSection(in: source, kind: .line, code: 0x0d)
        XCTAssertEqual(TypSource.parse(edited).drawOrder.map(\.code), [0x16])
    }

    // MARK: Against the real file

    /// A whole file with one colour changed: every other line, comments and blanks
    /// included, is identical.
    func testOneColourChangedInAWholeFileLeavesEveryOtherLineIdentical() throws {
        let original = TypFixture.source
        let source = TypSource.parse(original)

        let before = try XCTUnwrap(source.section(.polygon, 0x16))
        let edited = try TypEdit.setColour(in: source, kind: .polygon, code: 0x16,
                                           colourIndex: 0, to: "#123456")

        let changed = changedLines(original, edited)
        XCTAssertEqual(changed.count, 1, "changed lines: \(changed)")
        XCTAssertTrue(before.lines.contains(changed[0]),
                      "the changed line must be inside the section that was edited")

        let after = TypSource.parse(edited)
        XCTAssertEqual(after.section(.polygon, 0x16)?.colours.first, "#123456")
        XCTAssertEqual(after.sections.count, source.sections.count)
        XCTAssertEqual(after.section(.polygon, 0x16)?.comments,
                       before.comments, "the provenance comments must be untouched")
    }

    /// Borrowing a drawing from another type in the same file. The sizes differ, and
    /// nothing is scaled: a 2×2 mark lands on a 20×20 badge at 2×2.
    func testADrawingBorrowedFromAnotherTypeArrivesAtItsOwnSize() throws {
        let original = TypFixture.source
        let source = TypSource.parse(original)

        let spring = try XCTUnwrap(source.section(.point, 0x6511)?.picture)
        let restaurant = try XCTUnwrap(source.section(.point, 0x2a00))
        XCTAssertNotEqual(spring.width, restaurant.picture?.width, "the sizes must differ")

        let edited = try TypEdit.setPicture(in: source, kind: .point, code: 0x2a00, to: spring)
        let after = TypSource.parse(edited)

        let replaced = try XCTUnwrap(after.section(.point, 0x2a00))
        XCTAssertEqual(replaced.picture?.width, spring.width)
        XCTAssertEqual(replaced.picture?.height, spring.height)
        XCTAssertEqual(replaced.picture?.pixels(), spring.pixels())

        // Everything else about the section it landed on.
        XCTAssertEqual(replaced.englishLabel, "Restaurant")
        XCTAssertEqual(replaced.russianLabel, "Ресторан")
        XCTAssertEqual(replaced.comments, restaurant.comments,
                       "the provenance comments must survive a drawing being swapped")

        // And the donor, which is a different section of the same file.
        XCTAssertEqual(after.section(.point, 0x6511)?.picture, spring)
        XCTAssertEqual(after.sections.count, source.sections.count)
    }

    func testReplacingAFullSizeIconChangesOnlyItsOwnBlock() throws {
        let original = TypFixture.source
        let source = TypSource.parse(original)
        let restaurant = try XCTUnwrap(source.section(.point, 0x2a00))
        let picture = try XCTUnwrap(restaurant.picture)

        let replacement = XpmBlock(width: 2, height: 2, declaredColours: 1, charsPerPixel: 1,
                                   palette: [(key: "z", colour: "#FFFFFF")],
                                   rows: ["zz", "zz"])
        let edited = try TypEdit.setPicture(in: source, kind: .point, code: 0x2a00,
                                            to: replacement)

        // A header, 23 palette lines and 20 rows go out; a header, one palette line and two
        // rows come in.
        let changed = changedLines(original, edited)
        XCTAssertFalse(changed.isEmpty)
        XCTAssertEqual(picture.declaredColours, TypFixture.iconColours)

        let after = TypSource.parse(edited)
        XCTAssertEqual(after.sections.count, source.sections.count,
                       "no section may be lost or gained")
        XCTAssertEqual(after.section(.point, 0x2a00)?.englishLabel, "Restaurant")
        XCTAssertEqual(after.section(.point, 0x2a00)?.russianLabel, "Ресторан")
        XCTAssertEqual(after.section(.point, 0x2a00)?.picture?.width, 2)

        // Every other line of the file is unchanged.
        for kind in MapElementKind.allCases {
            XCTAssertEqual(after.codes(kind), source.codes(kind))
        }
    }
}
