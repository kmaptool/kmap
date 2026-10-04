import XCTest

@testable import kmap

#if os(Windows)
import WinSDK
#endif

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
        try FileTools.write(Data(count: bytes), to: url)
        return url
    }

    // MARK: Names

    func testARegionIdBecomesAFilesystemSafeToken() {
        // The result becomes part of the map file's name.
        XCTAssertEqual(FileTools.slugify("continent/large-region"), "continent-large-region")
        XCTAssertEqual(
            FileTools.slugify("continent/large-region/child-region"),
            "continent-large-region-child-region"
        )
        XCTAssertEqual(
            FileTools.slugify("parent-region/child-region"),
            "parent-region-child-region"
        )
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
        XCTAssertEqual(
            FileTools.contents(of: directory).map(\.lastPathComponent),
            ["a.hgt", "b.hgt", "c.HGT", "notes.txt"]
        )
        XCTAssertEqual(
            FileTools.contents(of: directory, extension: "hgt")
                .map(\.lastPathComponent),
            ["a.hgt", "b.hgt", "c.HGT"]
        )
        XCTAssertTrue(
            FileTools.contents(of: directory.appendingPathComponent("absent"))
                .isEmpty
        )
    }

    func testEmptyingADirectoryLeavesTheDirectoryItself() throws {
        _ = try write("one"); _ = try write("two")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
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

    func testCopyingMakesASecondFileAndRefusesToOverwriteOne() throws {
        let source = directory.appendingPathComponent("a.txt")
        let copy = directory.appendingPathComponent("b.txt")
        try FileTools.write("hello", to: source)
        try FileTools.copy(source, to: copy)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "hello")
        XCTAssertTrue(FileTools.exists(source))
        XCTAssertThrowsError(try FileTools.copy(source, to: copy))
    }

    func testOpeningForWritingCreatesAppendsOrStartsOver() throws {
        let url = directory.appendingPathComponent("stream.txt")
        let first = try FileTools.openForWriting(url)
        try first.write(contentsOf: Data("one".utf8))
        try first.close()
        let second = try FileTools.openForWriting(url)
        try second.write(contentsOf: Data("two".utf8))
        try second.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "onetwo")
        let fresh = try FileTools.openForWriting(url, appending: false)
        try fresh.write(contentsOf: Data("x".utf8))
        try fresh.close()
        // Not appending is a fresh file: nothing of "onetwo" is left behind the "x".
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "x")
    }

    // MARK: Types

    func testTheTypeIsTheItemsOwnAndALinkIsNotFollowed() throws {
        let file = try write("a.txt", bytes: 3)
        XCTAssertEqual(FileTools.type(of: file), .typeRegular)
        XCTAssertEqual(FileTools.type(of: directory), .typeDirectory)
        XCTAssertNil(FileTools.type(of: directory.appendingPathComponent("absent")))
        XCTAssertTrue(FileTools.isRegularFile(file))
        XCTAssertFalse(FileTools.isRegularFile(directory))
        XCTAssertTrue(FileTools.isDirectoryItself(directory))
        XCTAssertFalse(FileTools.isDirectoryItself(file))
        #if !os(Windows)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertEqual(FileTools.type(of: link), .typeSymbolicLink)
        #endif
    }

    func testAWalkGoesThroughLinkedFoldersAndNamesFilesThroughTheLink() throws {
        // The cache itself a link, and 1 source's folder a link to another disk.
        let elsewhere = directory.appendingPathComponent("elsewhere/COP1")
        let disk = directory.appendingPathComponent("disk/fab")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        try FileTools.write(Data(), to: elsewhere.appendingPathComponent("N44E033.hgt"))
        try FileTools.write(Data(), to: elsewhere.appendingPathComponent(".N44E034.hgt"))
        try FileTools.write(Data(), to: disk.appendingPathComponent("N45E033.hgt"))
        let cache = directory.appendingPathComponent("hgt")
        do {
            try FileManager.default.createSymbolicLink(
                at: cache,
                withDestinationURL: directory.appendingPathComponent("elsewhere")
            )
            try FileManager.default.createSymbolicLink(
                at: cache.appendingPathComponent("FAB1"),
                withDestinationURL: disk
            )
            // A link back up, which the walk must not follow round.
            try FileManager.default.createSymbolicLink(
                at: disk.appendingPathComponent("up"),
                withDestinationURL: directory
            )
        } catch {
            throw XCTSkip("this machine does not let a test make links: \(error)")
        }
        let found = FileTools.filesThroughLinks(under: cache, extension: "hgt")
        let shown = found.map { $0.pathComponents.suffix(3).joined(separator: "/") }
        XCTAssertEqual(shown, ["hgt/COP1/N44E033.hgt", "hgt/FAB1/N45E033.hgt"])
    }

    #if os(Windows)
    /// Foundation's URL resource values trap on Windows on a file of 2 to 4 GB, which a
    /// map of a large country is. Every helper that looks at a file must answer for one.
    func testAFileOfSeveralGigabytesIsAnsweredFor() throws {
        let big = try write("big.img")
        try Self.makeSparse(big, size: 2_500_000_000)
        XCTAssertEqual(FileTools.size(of: big), 2_500_000_000)
        XCTAssertEqual(FileTools.type(of: big), .typeRegular)
        XCTAssertNotNil(FileTools.modified(of: big))
        XCTAssertEqual(FileTools.allFiles(under: directory).map(\.lastPathComponent), ["big.img"])
        XCTAssertTrue(FileTools.isRegularFile(big))
        XCTAssertFalse(FileTools.isDirectoryItself(big))
        XCTAssertFalse(TypLibrary.isDirectory(big))
    }

    /// Sized without writing, so the test costs no disk space.
    private static func makeSparse(_ url: URL, size: Int64) throws {
        let handle = url.nativePath.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw CocoaError(.fileWriteUnknown) }
        defer { CloseHandle(handle) }
        // FSCTL_SET_SPARSE.
        var returned: DWORD = 0
        var end = LARGE_INTEGER()
        end.QuadPart = size
        guard DeviceIoControl(handle, 0x0009_00C4, nil, 0, nil, 0, &returned, nil),
            SetFilePointerEx(handle, end, nil, DWORD(FILE_BEGIN)),
            SetEndOfFile(handle)
        else { throw CocoaError(.fileWriteUnknown) }
    }
    #endif
}
