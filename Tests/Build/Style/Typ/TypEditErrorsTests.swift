import XCTest
@testable import kmap

/// What an edit that cannot be made says, and the branches around a section's edges.
final class TypEditErrorsTests: XCTestCase {

    private let source = TypSource.parse("""
        [_polygon]
        Type=0x10
        Xpm="0 0 1 0"
        "1 c #112233"
        [end]

        [_line]
        Type=0x05
        [end]
        """)

    func testEveryRefusalNamesWhatItIsAbout() {
        let refusals: [(TypEdit.EditError, String)] = [
            (.noSuchSection(.polygon, 0x1f), "0x1f"),
            (.noPicture(0x05), "0x05"),
            (.noSuchColour(0x10, 1), "0x10"),
            (.notAColour("grass"), "grass"),
            (.notALevel(0), "0"),
            (.noNightForm(0x10), "0x10"),
        ]
        for (error, mention) in refusals {
            let text = error.errorDescription ?? ""
            XCTAssertTrue(text.lowercased().contains(mention), "\(error): \(text)")
        }
        XCTAssertFalse((TypEdit.EditError.noDrawOrder.errorDescription ?? "").isEmpty)
        XCTAssertTrue((TypEdit.AddError.alreadyThere(.line, 0x05).errorDescription ?? "")
            .lowercased().contains("0x05"))
    }

    func testEditsToASectionThatIsNotThereAreRefused() {
        XCTAssertThrowsError(try TypEdit.setLabel(in: source, kind: .polygon, code: 0x77,
                                                  language: 0x04, to: "x"))
        XCTAssertThrowsError(try TypEdit.setFontStyle(in: source, kind: .polygon, code: 0x77,
                                                      to: "NoLabel"))
        XCTAssertThrowsError(try TypEdit.removeSection(in: source, kind: .point, code: 0x77))
    }

    func testAColourPastThePaletteIsRefused() {
        XCTAssertThrowsError(try TypEdit.setColour(in: source, kind: .polygon, code: 0x10,
                                                   colourIndex: 5, to: "#FFFFFF"))
        XCTAssertThrowsError(try TypEdit.setColour(in: source, kind: .polygon, code: 0x10,
                                                   colourIndex: 0, to: "grass"))
    }

    func testAddingWhatIsAlreadyThereIsRefused() {
        XCTAssertThrowsError(try TypEdit.addSection(in: source, kind: .line, code: 0x05))
    }

    func testANewSectionWearsThePlaceholderUntilSomebodyChooses() throws {
        let text = try TypEdit.addSection(in: source, kind: .polygon, code: 0x1f)
        XCTAssertTrue(text.contains(TypEdit.placeholderColour))
    }

    func testRemovingTheLastSectionTakesTheBlankLineAboveIt() throws {
        // No blank line follows the last section, so the one before it goes instead and
        // the file does not end in a double gap.
        let text = try TypEdit.removeSection(in: source, kind: .line, code: 0x05)
        XCTAssertFalse(text.contains("[_line]"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
        XCTAssertTrue(text.contains("Type=0x10"), "the other section is untouched")
    }

    // MARK: The draw order

    func testAnEntryIsReadHoweverItIsSpelt() throws {
        let table = TypSource.parse("""
            [_drawOrder]
            Type=0x04b,1
            type=32 , 2
            Type=0x10,3 ; an older kmap wrote its note here
            not an entry
            [end]
            """)
        // Moving each proves it was found: a missing entry would be added, not moved.
        for code in [0x4b, 0x32, 0x10] {
            let text = try TypEdit.setDrawOrderLevel(in: table, code: code, to: 5)
            XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasSuffix(",5") }.count, 1)
            XCTAssertTrue(text.contains("not an entry"), "other lines are left as they are")
        }
    }

    func testAPolygonMissingFromAnEmptyTableIsAdded() throws {
        let table = TypSource.parse("[_drawOrder]\n[end]\n")
        let text = try TypEdit.setDrawOrderLevel(in: table, code: 0x1f, to: 4)
        XCTAssertTrue(text.contains("Type=0x1f,4"))
    }

    func testAFileWithoutATableCannotBeOrdered() {
        XCTAssertThrowsError(try TypEdit.setDrawOrderLevel(in: source, code: 0x10, to: 2))
        XCTAssertThrowsError(try TypEdit.setDrawOrderLevel(
            in: TypSource.parse("[_drawOrder]\n[end]\n"), code: 0x10, to: 0), "levels start at 1")
    }
}
