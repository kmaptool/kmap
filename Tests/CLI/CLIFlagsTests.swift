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
        // Infinity and not-a-number parse, and are not numbers a flag can hold.
        let flags = CLI.Flags(["--step=nan", "--mapid=12,000", "--limit=4.5", "--radius=1e400", "--raw"], valued: [])
        XCTAssertEqual(flags.notNumbers(["step", "mapid", "limit", "radius", "absent"]), ["step", "mapid", "radius"])
        XCTAssertNil(flags.double("radius"))
        XCTAssertEqual(flags.notWholeNumbers(["limit"]), ["limit"])
        // A valued flag with nothing after it holds no number either.
        let bare = CLI.Flags(["--step", "--raw"], valued: ["step"])
        XCTAssertEqual(bare.notNumbers(["step"]), ["step"])
    }

    /// `kmap build` reads `--key value` as `--key=value`, and a switch never takes the next word.
    func testABuildOptionTakesItsValueAfterASpace() {
        let flags = CLI.Flags(
            ["--profile", "GPSMap 67", "monaco", "--dem", "--out", "/tmp/x"],
            valued: CLI.buildValuedOptions
        )
        XCTAssertEqual(flags.value("profile"), "GPSMap 67")
        XCTAssertEqual(flags.value("out"), "/tmp/x")
        XCTAssertEqual(flags.positionals, ["monaco"])
        XCTAssertTrue(flags.has("dem"))
        XCTAssertFalse(CLI.buildValuedOptions.contains("descriptions"), "it stands alone as well")
        XCTAssertTrue(
            CLI.BuildOptions(CLI.Flags(["--style"], valued: CLI.buildValuedOptions)).refused.contains {
                $0.contains("--style needs a value")
            }
        )
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

    /// A typo or a stray argument stops the command with exit code 2 before any work.
    func testATypoOrAStrayArgumentIsRefused() async {
        for line in [
            ["fetch-dem", "N00E000", "--sorce=view1"],
            ["dem-cost", "monaco", "--source=copernicus1"],
            ["dem-cost", "monaco", "--sources=bogus"],
            ["repair-roads", "in.pbf", "out.pbf", "--no-bridge"],
            ["repair-roads", "in.pbf", "out.pbf", "extra.pbf"],
            ["split", "in.pbf", "--output-dir", "tiles", "--max-node", "800000"],
            ["contours", "t.hgt", "--setp", "10"],
            ["burn-peaks", "--pbf", "a.pbf", "b.pbf", "--hgt-dir", "d", "--out", "o.pbf"],
            ["typinfo", "map.img", "--bogus"],
            ["styles", "--bogus"],
            ["doctor", "--bogus"],
            ["hideable", "--regenrate"]
        ] {
            let code = await CLI.run(line)
            XCTAssertEqual(code, 2, line.joined(separator: " "))
        }
    }

    func testTheFlagsACommandReadsAreKnownToIt() {
        let flags = CLI.Flags(["t.hgt", "--step", "10", "--raw", "--no-split"], valued: ["step"])
        XCTAssertNil(flags.refusal("contours", knows: ["step", "raw", "no-split"], positionals: 1))
    }
}
