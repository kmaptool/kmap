import XCTest

@testable import kmap

/// The one way kmap writes, moves and removes files, on whichever platform this is.
final class FileWriteTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filewrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    func testTextComesBackAsWrittenAndReplacesWhatWasThere() throws {
        let file = dir.appendingPathComponent("lines")
        try FileTools.write("first\n", to: file)
        try FileTools.write("second: \u{439}\u{446}\n", to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second: \u{439}\u{446}\n")
        XCTAssertEqual(FileTools.contents(of: dir).map(\.lastPathComponent), ["lines"], "no temporary file left")
    }

    func testDataComesBackByteForByte() throws {
        let file = dir.appendingPathComponent("blob.bin")
        let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try FileTools.write(bytes, to: file)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testAWriteIntoAMissingFolderIsRefused() {
        let file = dir.appendingPathComponent("nowhere/lines")
        XCTAssertThrowsError(try FileTools.write("x", to: file))
        XCTAssertFalse(FileTools.exists(file))
    }

    func testMoveRefusesAnOccupiedDestination() throws {
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try FileTools.write("a", to: a)
        try FileTools.move(a, to: b)
        XCTAssertFalse(FileTools.exists(a))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "a")
        try FileTools.write("again", to: a)
        XCTAssertThrowsError(try FileTools.move(a, to: b))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "a", "the occupant is untouched")
    }

    func testRemoveTakesAWholeTreeAndSaysSoForNothing() throws {
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        let deep = tree.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileTools.write("leaf", to: deep.appendingPathComponent("leaf"))
        try FileTools.write("top", to: tree.appendingPathComponent("top"))
        try FileTools.remove(tree)
        XCTAssertFalse(FileTools.exists(tree))
        XCTAssertThrowsError(try FileTools.remove(tree), "nothing there to remove")
        FileTools.removeIfPresent(tree)
    }

    func testEmptyDirectoryKeepsTheDirectory() throws {
        try FileTools.write("x", to: dir.appendingPathComponent("x"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub/inner"),
            withIntermediateDirectories: true
        )
        FileTools.emptyDirectory(dir)
        XCTAssertTrue(FileTools.exists(dir))
        XCTAssertEqual(FileTools.contents(of: dir), [])
    }
}
