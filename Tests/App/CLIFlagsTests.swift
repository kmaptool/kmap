import XCTest

@testable import kmap

/// Flag parsing: `--out file` and `--out=file` are equivalent, and a flag's value is
/// never taken for a positional argument.
final class CLIFlagsTests: XCTestCase {
    func testBothSpellingsOfAValueRead() {
        let equals = CLI.Flags(["--out=sheet.txt"], valued: ["out"])
        let spaced = CLI.Flags(["--out", "sheet.txt"], valued: ["out"])
        XCTAssertEqual(equals.value("out"), "sheet.txt")
        XCTAssertEqual(spaced.value("out"), "sheet.txt")
        XCTAssertTrue(spaced.has("out"))
        XCTAssertTrue(spaced.positionals.isEmpty, "the value is not a positional")
    }

    func testOnlyADeclaredFlagTakesTheNextArgument() {
        let flags = CLI.Flags(["--quiet", "map.img", "--step", "0.5"], valued: ["step"])
        XCTAssertTrue(flags.has("quiet"))
        XCTAssertNil(flags.value("quiet"))
        XCTAssertEqual(flags.positionals, ["map.img"])
        XCTAssertEqual(flags.double("step"), 0.5)
    }

    func testAValuedFlagDoesNotSwallowTheFlagAfterIt() {
        // `--out --attach` used to write a file called "--attach" and lose the flag.
        let flags = CLI.Flags(["map.img", "--out", "--attach"], valued: ["out"])
        XCTAssertTrue(flags.has("out"))
        XCTAssertNil(flags.value("out"))
        XCTAssertTrue(flags.has("attach"))
    }

    func testAFlagThatShouldHoldANumberButDoesNotIsNamed() {
        let flags = CLI.Flags(["--step=nan", "--mapid=12,000", "--limit=4.5", "--raw"], valued: [])
        XCTAssertEqual(flags.notNumbers(["step", "mapid", "limit", "absent"]), ["mapid"])
        // A valued flag with nothing after it holds no number either.
        let bare = CLI.Flags(["--step", "--raw"], valued: ["step"])
        XCTAssertEqual(bare.notNumbers(["step"]), ["step"])
    }

    func testARepeatedFlagKeepsEveryValue() {
        let flags = CLI.Flags(
            ["map.img", "--extract", "a.pbf", "--extract=b.pbf"],
            valued: ["extract"]
        )
        XCTAssertEqual(flags.values("extract"), ["a.pbf", "b.pbf"])
        XCTAssertEqual(flags.value("extract"), "b.pbf", "the last one where one is asked for")
        XCTAssertEqual(flags.positionals, ["map.img"])
    }

    func testAValuedFlagAtTheEndIsMerelyPresent() {
        let flags = CLI.Flags(["in.pbf", "--labels"], valued: ["labels"])
        XCTAssertTrue(flags.has("labels"))
        XCTAssertNil(flags.value("labels"))
        XCTAssertEqual(flags.positionals, ["in.pbf"])
    }

    func testASingleDashIsNotAFlag() {
        let flags = CLI.Flags(["-h", "--", "x"])
        XCTAssertEqual(flags.positionals, ["-h", "--", "x"])
    }
}
