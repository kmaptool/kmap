import XCTest

@testable import kmap

/// The three placements every kmap rule block goes through, and the marker that keeps a
/// directory from being amended twice.
final class StyleSpliceTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")
    private let marker = "# --- kmap: test block"
    private var block: String { "\(marker) ---\ntest=yes [0x10 resolution 24]\n" }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-splice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var catalog: StyleCatalog {
        let settings = SettingsStore()
        return StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
    }

    private func write(_ text: String, to name: String = "points") throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String = "points") throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func testASplicedBlockGoesAheadOfFinalize() throws {
        try write("a=b [0x01]\n<finalize>\nname=* {}\n")
        XCTAssertTrue(try catalog.spliceRules(block, marked: marker, intoFile: "points", in: directory))
        let text = try read()
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: marker)).lowerBound,
            try XCTUnwrap(text.range(of: "<finalize>")).lowerBound
        )
    }

    func testWithoutFinalizeTheBlockGoesAtTheEnd() throws {
        try write("a=b [0x01]\n")
        try catalog.spliceRules(block, marked: marker, intoFile: "points", in: directory)
        XCTAssertTrue(try read().hasSuffix(block))
    }

    func testAPrependedBlockIsTheFirstThingInTheFile() throws {
        try write("a=b [0x01]\n")
        XCTAssertTrue(try catalog.prependRules(block, marked: marker, toFile: "points", in: directory))
        XCTAssertTrue(try read().hasPrefix(block))
        XCTAssertTrue(try read().hasSuffix("a=b [0x01]\n"))
    }

    func testAnInsertedBlockStartsTheLineOfItsAnchor() throws {
        try write("first=yes [0x01]\n  anchor=here [0x02]\nlast=yes [0x03]\n")
        let outcome = try catalog.insertRules(
            block,
            marked: marker,
            beforeLineWith: "anchor=here",
            intoFile: "points",
            in: directory
        )
        guard case .added = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try read(), "first=yes [0x01]\n" + block + "  anchor=here [0x02]\nlast=yes [0x03]\n")
    }

    func testAnAnchorOnTheFirstLineIsStillALineStart() throws {
        try write("anchor=here [0x02]\n")
        _ = try catalog.insertRules(
            block,
            marked: marker,
            beforeLineWith: "anchor=here",
            intoFile: "points",
            in: directory
        )
        XCTAssertEqual(try read(), block + "anchor=here [0x02]\n")
    }

    func testAMissingAnchorWritesNothingAndSaysSo() throws {
        let stock = "first=yes [0x01]\n"
        try write(stock)
        let outcome = try catalog.insertRules(
            block,
            marked: marker,
            beforeLineWith: "nowhere",
            intoFile: "points",
            in: directory
        )
        guard case .missingAnchor = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try read(), stock)
    }

    func testTheMarkerKeepsEveryPlacementFromRunningTwice() throws {
        try write("anchor=here [0x02]\n<finalize>\n")
        let styles = catalog
        XCTAssertTrue(try styles.spliceRules(block, marked: marker, intoFile: "points", in: directory))
        let once = try read()
        XCTAssertFalse(try styles.spliceRules(block, marked: marker, intoFile: "points", in: directory))
        XCTAssertFalse(try styles.prependRules(block, marked: marker, toFile: "points", in: directory))
        let again = try styles.insertRules(
            block,
            marked: marker,
            beforeLineWith: "anchor=here",
            intoFile: "points",
            in: directory
        )
        guard case .leftAlone = again else { return XCTFail("\(again)") }
        XCTAssertEqual(try read(), once)
    }

    func testAStyleWithoutTheFileIsLeftAlone() throws {
        XCTAssertFalse(try catalog.spliceRules(block, marked: marker, intoFile: "lines", in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lines").path))
    }

    func testAChangeThatDeclinesLeavesTheFileUnwritten() throws {
        try write("a=b\n")
        let before =
            try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("points").path
            )[.modificationDate] as? Date
        try catalog.amendRuleFile("points", in: directory) { text in
            text = "scribbled"
            return false
        }
        XCTAssertEqual(try read(), "a=b\n")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("points").path
            )[.modificationDate] as? Date,
            before
        )
    }
}
