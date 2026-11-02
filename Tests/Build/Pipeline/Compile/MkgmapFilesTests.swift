import XCTest

@testable import kmap

#if os(Windows)
import WinSDK
#endif

/// The files mkgmap's combiners take in, read from the log its main class writes.
final class MkgmapFilesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBothPassesAreCounted() throws {
        let log = """
            Submitting job 63240001.osm.pbf
            Combining maps
              /work/tiles/ovm_63240001.img
              63240001.osm.pbf -> /work/tiles/63240001.img
              63240002.osm.pbf -> /work/tiles/63240002.img

            """
        try log.write(
            to: directory.appendingPathComponent(BuildPipeline.MkgmapFiles.name),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(BuildPipeline.MkgmapFiles.named(by: directory), 3)
    }

    func testNoLogYetIsNothingNamed() {
        XCTAssertEqual(BuildPipeline.MkgmapFiles.named(by: directory), 0)
    }

    func testTheOverviewNamesTheMapsOnceMore() {
        let files = ["1.img", "2.img", "style.typ"].map { URL(fileURLWithPath: "/tiles/" + $0) }
        XCTAssertEqual(BuildPipeline.MkgmapFiles.mentions(of: files), 5)
    }

    func testClearingRemovesTheLogAndItsLock() throws {
        let name = BuildPipeline.MkgmapFiles.name
        for file in [name, name + ".lck"] {
            try "x".write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        BuildPipeline.MkgmapFiles.clear(in: directory)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testThePackingRunTakesTheTYPInAsOneMoreFile() throws {
        let pipeline = PipelineFixture.pipeline()
        let tiles = [URL(fileURLWithPath: "/tiles/1.img"), URL(fileURLWithPath: "/tiles/2.img")]
        let typ = directory.appendingPathComponent("style.typ")
        XCTAssertEqual(pipeline.combineInputs(tiles, typ: typ).count, 2, "no TYP on disk")
        try "x".write(to: typ, atomically: true, encoding: .utf8)
        XCTAssertEqual(pipeline.combineInputs(tiles, typ: typ), tiles + [typ])
    }

    func testTheConsoleKeepsMkgmapsOwnFormatAndOnlyTheMainClassGoesToTheFile() {
        let settings = BuildPipeline.MkgmapFiles.logging
        XCTAssertTrue(
            settings.contains("java.util.logging.ConsoleHandler.formatter=uk.me.parabola.log.UsefulFormatter")
        )
        XCTAssertTrue(settings.contains("uk.me.parabola.mkgmap.main.Main.handlers=java.util.logging.FileHandler"))
        XCTAssertTrue(settings.contains("java.util.logging.FileHandler.pattern=\(BuildPipeline.MkgmapFiles.name)"))
    }

    func testALogHeldOpenByItsWriterIsCounted() throws {
        let url = directory.appendingPathComponent(BuildPipeline.MkgmapFiles.name)
        try FileTools.write(Data(), to: url)
        let line = Data("  a.img\n".utf8)
        #if os(Windows)
        let handle = url.nativePath.withCString(encodedAs: UTF16.self) {
            CreateFileW(
                $0,
                DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        let held = try XCTUnwrap(handle == INVALID_HANDLE_VALUE ? nil : handle)
        defer { CloseHandle(held) }
        var wrote: DWORD = 0
        XCTAssertTrue(line.withUnsafeBytes { WriteFile(held, $0.baseAddress, DWORD($0.count), &wrote, nil) })
        #else
        let held = try FileHandle(forWritingTo: url)
        defer { try? held.close() }
        held.write(line)
        #endif
        XCTAssertEqual(BuildPipeline.MkgmapFiles.named(by: directory), 1)
    }
}
