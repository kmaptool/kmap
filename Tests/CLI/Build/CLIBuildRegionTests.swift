import XCTest

@testable import kmap

final class CLIBuildRegionTests: XCTestCase {
    private func refusal(_ arguments: [String]) -> String? {
        CLI.regionRefusal(CLI.Flags(arguments, valued: CLI.buildValuedOptions), arguments: arguments)
    }

    func testOneRegionIsWhatBuildTakes() {
        XCTAssertNil(refusal(["austria", "--interval", "20"]))
    }

    /// The value of a mistyped option stands alone, and is not taken for a region.
    func testAMistypedOptionIsNamedRatherThanItsValueTakenForARegion() throws {
        let said = try XCTUnwrap(refusal(["austria", "--intreval", "20"]))
        XCTAssertTrue(said.contains("--intreval is not an option"), said)
        XCTAssertFalse(said.contains("is a second"), said)
    }

    func testASecondRegionIsSaidToBeOne() throws {
        let said = try XCTUnwrap(refusal(["austria", "germany"]))
        XCTAssertTrue(said.contains("\"germany\" is a second"), said)
    }

    /// An option taking its value only after `=` leaves a spaced value alone.
    func testAValueAfterASpaceIsSaidToWantAnEqualsSign() throws {
        let said = try XCTUnwrap(refusal(["austria", "--descriptions", "ru"]))
        XCTAssertTrue(said.contains("--descriptions=ru"), said)
        XCTAssertFalse(said.contains("is a second"), said)
    }

    /// A switch takes no value: what follows it is the second region it looks like.
    func testASwitchBeforeASecondRegionIsNoValue() throws {
        let said = try XCTUnwrap(refusal(["austria", "--keep-work", "germany"]))
        XCTAssertTrue(said.contains("\"germany\" is a second"), said)
    }

    func testTheSpacedValueIsFoundBeforeTheRegionToo() throws {
        let said = try XCTUnwrap(refusal(["--descriptions", "ru", "austria"]))
        XCTAssertTrue(said.contains("--descriptions=ru"), said)
    }

    func testNoRegionAtAllIsAsked() {
        XCTAssertEqual(refusal(["--interval", "20"]), "build needs a region id, e.g. austria")
    }
}
