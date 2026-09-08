import XCTest
@testable import kmap

/// The command that prints what a compiled TYP holds: what it accepts, what it refuses,
/// and that a map is opened by lifting its TYP out rather than being read as one.
final class TypDumpTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-typdump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNoArgumentsAsksForOne() {
        XCTAssertEqual(CLI.typdump([]), 2)
        XCTAssertEqual(CLI.typdump(["--all"]), 2, "flags alone name no file")
    }

    func testAFileThatIsNotThereIsRefused() {
        XCTAssertEqual(CLI.typdump([directory.appendingPathComponent("nope.typ").path]), 2)
    }

    func testSomethingThatIsNotATypIsRefused() throws {
        let url = directory.appendingPathComponent("plain.typ")
        try Data(repeating: 0x41, count: 400).write(to: url)
        XCTAssertEqual(CLI.typdump([url.path]), 1)
    }

    func testAShortFileIsRefusedRatherThanRead() throws {
        let url = directory.appendingPathComponent("short.typ")
        try Data([0x00, 0x01]).write(to: url)
        XCTAssertEqual(CLI.typdump([url.path]), 1)
    }

    /// Skips unless the library holds a TYP; none is carried as a fixture.
    func testARealTypIsReadAndAgreesWithTheDecoder() throws {
        let found = FileTools.contents(of: TypLibrary.directory, extension: "typ").first
        try XCTSkipUnless(found != nil, "no TYP in the library")
        let typ = try TypBinary.read(found!)
        XCTAssertEqual(CLI.typdump([found!.path, "--all"]), 0)
        XCTAssertFalse(typ.all.isEmpty)
        XCTAssertEqual(typ.all.count, typ.polygons.count + typ.lines.count + typ.points.count)
    }
}
