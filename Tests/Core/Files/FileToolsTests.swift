import XCTest
@testable import kmap

/// The small file helpers: name slugs, existence and size, directory contents.
final class FileToolsTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, bytes: Int = 0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    // MARK: Names

    func testARegionIdBecomesAFilesystemSafeToken() {
        // The result becomes part of the map file's name.
        XCTAssertEqual(FileTools.slugify("continent/large-region"), "continent-large-region")
        XCTAssertEqual(FileTools.slugify("continent/large-region/child-region"),
                       "continent-large-region-child-region")
        XCTAssertEqual(FileTools.slugify("parent-region/child-region"),
                       "parent-region-child-region")
        XCTAssertEqual(FileTools.slugify("border-region-district"), "border-region-district")
        XCTAssertEqual(FileTools.slugify("Border-Region"), "border-region")
    }

    func testNothingThatCouldConfuseAPathSurvives() {
        XCTAssertFalse(FileTools.slugify("../../etc/passwd").contains("/"))
        XCTAssertFalse(FileTools.slugify("a b\tc").contains(" "))
        XCTAssertFalse(FileTools.slugify("what?*|<>").contains("?"))
        // Leading and trailing separators go, so no file is named "-something".
        XCTAssertEqual(FileTools.slugify("/leading/"), "leading")
        XCTAssertEqual(FileTools.slugify("---"), "")
    }

    // MARK: Asking about files

    func testSizeAndExistenceAnswerZeroAndFalseForSomethingAbsent() throws {
        let absent = directory.appendingPathComponent("nothing")
        XCTAssertFalse(FileTools.exists(absent))
        XCTAssertEqual(FileTools.size(of: absent), 0)
        XCTAssertNil(FileTools.modified(of: absent))

        let real = try write("real.bin", bytes: 1234)
        XCTAssertTrue(FileTools.exists(real))
        XCTAssertEqual(FileTools.size(of: real), 1234)
        XCTAssertNotNil(FileTools.modified(of: real))
    }

    func testContentsAreSortedAndCanBeFilteredByExtensionWhateverItsCase() throws {
        _ = try write("b.hgt"); _ = try write("a.hgt")
        _ = try write("c.HGT"); _ = try write("notes.txt")
        XCTAssertEqual(FileTools.contents(of: directory).map(\.lastPathComponent),
                       ["a.hgt", "b.hgt", "c.HGT", "notes.txt"])
        XCTAssertEqual(FileTools.contents(of: directory, extension: "hgt")
                        .map(\.lastPathComponent), ["a.hgt", "b.hgt", "c.HGT"])
        XCTAssertTrue(FileTools.contents(of: directory.appendingPathComponent("absent"))
                        .isEmpty)
    }

    func testEmptyingADirectoryLeavesTheDirectoryItself() throws {
        _ = try write("one"); _ = try write("two")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        FileTools.emptyDirectory(directory)
        XCTAssertTrue(FileTools.exists(directory))
        XCTAssertTrue(FileTools.contents(of: directory).isEmpty)
        // And on something that is not there, it does nothing rather than throwing.
        FileTools.emptyDirectory(directory.appendingPathComponent("absent"))
    }

    func testRemovingSomethingAbsentIsNotAnError() {
        FileTools.removeIfPresent(directory.appendingPathComponent("absent"))
    }

    func testTheFreeSpaceOfARealVolumeIsAPositiveNumber() {
        // Read before a build to refuse one that cannot finish; zero would refuse them all.
        XCTAssertGreaterThan(FileTools.freeSpaceBytes(at: directory), 0)
    }
}
