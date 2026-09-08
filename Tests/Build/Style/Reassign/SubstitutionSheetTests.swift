import XCTest
@testable import kmap

/// One reading of the sheet, for the build that applies it and the screen that lists it.
final class SubstitutionSheetTests: XCTestCase {

    private let sheet = """
    # prose before anything
    @@ points
    - sport=airport [0x2d0b resolution 24]

    # a bare deletion, then prose, then the next entry
    - amenity=prison [0x3007 resolution 24]
    + amenity=prison [0x661a resolution 24]
    - two=lines [0x10 resolution 24]
    -     [0x11 resolution 22]
    + two=lines [0x12 resolution 24]
    @@ lines
    - highway=path [0x16 resolution 22]
    + highway=path [0x16 resolution 23]
    + highway=path [0x10016 resolution 23 continue]
    """

    func testEveryShapeASheetCanTakeReadsAsItsOwnEntry() {
        let entries = SubstitutionSheet.parse(sheet)
        XCTAssertEqual(entries.map(\.file), ["points", "points", "points", "lines"])
        XCTAssertEqual(entries[0].old, ["sport=airport [0x2d0b resolution 24]"])
        XCTAssertEqual(entries[0].new, [], "a - with no + deletes the rule")
        XCTAssertEqual(entries[1].old, ["amenity=prison [0x3007 resolution 24]"],
                       "prose between entries keeps them apart")
        XCTAssertEqual(entries[2].old.count, 2, "adjacent - lines are one two-line anchor")
        XCTAssertEqual(entries[3].new.count, 2, "one - may become several +")
    }

    func testTheListingIsTheApplication() throws {
        // The screen and the build read the sheet through the same parser, so the entries
        // listed are the ones applied.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmap-sheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("reassignments.txt")
        try sheet.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(RuleReassignments.entries(in: file), SubstitutionSheet.parse(sheet))

        try "sport=airport [0x2d0b resolution 24]\namenity=prison [0x3007 resolution 24]\n"
            .write(to: dir.appendingPathComponent("points"), atomically: true, encoding: .utf8)
        try "highway=path [0x16 resolution 22]\n"
            .write(to: dir.appendingPathComponent("lines"), atomically: true, encoding: .utf8)
        let result = try StyleCatalog.applySubstitutions(sheet, in: dir)
        XCTAssertEqual(result.applied, 3)
        XCTAssertEqual(result.missed.count, 1, "the two-line rule is not in this points file")
    }

    func testLinesBeforeAnyFileHeaderAreNotAnEntry() {
        let stray = "- orphan [0x10 resolution 24]\n+ orphan [0x11 resolution 24]\n@@ points\n- a=b [0x10]\n"
        let entries = SubstitutionSheet.parse(stray)
        XCTAssertEqual(entries.map(\.file), ["", "points"])
        // The applier skips what has no file to land in.
        XCTAssertTrue(entries.contains { $0.file.isEmpty })
    }
}
