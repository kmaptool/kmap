import XCTest

@testable import kmap

/// Command lines that would have run wrong are refused before any work.
final class CLIRefusalsTests: XCTestCase {
    /// Written over its own input, an extract would be lost to a few kilobytes of POIs.
    func testAPassWritingOverItsInputIsRefused() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("same-\(UUID().uuidString).osm.pbf")
            .path
        let gpi = await CLI.run(["make-gpi", file, file])
        let repair = await CLI.run(["repair-roads", file, file])
        XCTAssertEqual(gpi, 2)
        XCTAssertEqual(repair, 2)
    }

    /// A flag after `regions` is a mistake, not a search for its text.
    func testAFlagToRegionsIsRefused() async {
        let code = await CLI.run(["regions", "--bogus"])
        XCTAssertEqual(code, 2)
    }

    /// `--help` after any command shows the usage.
    func testHelpAfterACommandShowsTheUsage() async {
        for command in ["typdump", "regions", "recover", "make-gpi"] {
            let code = await CLI.run([command, "--help"])
            XCTAssertEqual(code, 0, command)
        }
    }

    /// `kmap build` refuses an overlap off its step as a profile does.
    func testABuildRefusesAnOverlapOffItsStep() async {
        let code = await CLI.run(["build", "region-a", "--overlap=100"])
        XCTAssertEqual(code, 2)
    }

    /// `--attach` asks about copying a map's TYP only once the map is there to copy.
    func testAttachingToAMissingMapFailsBeforeAnyQuestion() async {
        let code = await CLI.run(["recover", "/nonexistent-\(UUID().uuidString).img", "--attach"])
        XCTAssertEqual(code, 1)
    }

    /// A second map would be ignored.
    func testRecoverTakesOneMap() async {
        let code = await CLI.run(["recover", "a.img", "b.img"])
        XCTAssertEqual(code, 2)
    }
}
