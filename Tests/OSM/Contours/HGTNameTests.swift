import XCTest
@testable import kmap

/// Naming of elevation tiles: a tile is named for its south-west corner, in all four
/// quadrants.
final class HGTNameTests: XCTestCase {

    func testTheFourQuadrantsAreNamedFromTheirCorner() {
        XCTAssertEqual(HGTName.of(lat: 44, lon: 33), "N44E033")
        XCTAssertEqual(HGTName.of(lat: -34, lon: -71), "S34W071")
        XCTAssertEqual(HGTName.of(lat: 60, lon: -2), "N60W002")
        XCTAssertEqual(HGTName.of(lat: -9, lon: 116), "S09E116")
    }

    func testTheEquatorAndTheMeridianBelongToNorthAndEast() {
        XCTAssertEqual(HGTName.of(lat: 0, lon: 0), "N00E000")
        XCTAssertEqual(HGTName.of(lat: 0, lon: 7), "N00E007")
        XCTAssertEqual(HGTName.of(lat: 51, lon: 0), "N51E000")
    }

    func testACoordinateFallsIntoTheTileBelowAndLeftOfIt() {
        // The name is the south-west corner, so a coordinate rounds down: towards the
        // pole in the southern hemisphere, not towards the equator.
        XCTAssertEqual(HGTName.of(lat: 44.9, lon: 33.1), "N44E033")
        XCTAssertEqual(HGTName.of(lat: 44.0, lon: 33.0), "N44E033")
        XCTAssertEqual(HGTName.of(lat: -33.1, lon: -70.9), "S34W071")
        XCTAssertEqual(HGTName.of(lat: -0.1, lon: -0.1), "S01W001")
        XCTAssertEqual(HGTName.of(lat: 0.0, lon: 0.0), "N00E000")
    }

    func testANameReadsBackAsTheCornerItStandsFor() {
        for (lat, lon) in [(44, 33), (-34, -71), (0, 0), (-1, -1), (60, -2), (-89, 179)] {
            let name = HGTName.of(lat: lat, lon: lon)
            let corner = HGTName.corner(of: name)
            XCTAssertEqual(corner?.lat, lat, name)
            XCTAssertEqual(corner?.lon, lon, name)
        }
    }

    func testTheExtensionIsOptionalAndTheCaseDoesNotMatter() {
        XCTAssertEqual(HGTName.corner(of: "N44E033.hgt")?.lat, 44)
        XCTAssertEqual(HGTName.corner(of: "n44e033")?.lon, 33)
        XCTAssertEqual(HGTName.corner(of: "s34w071.hgt")?.lat, -34)
    }

    func testSomethingThatIsNotATileNameIsRefusedRatherThanGuessedAt() {
        // A tile directory also holds index files and stray downloads.
        for wrong in ["", "N44", "X44E033", "N44X033", "NAAE033", "N44E0AA",
                      "viewfinderHgtIndex_1.txt", "N44E33"] {
            XCTAssertNil(HGTName.corner(of: wrong), wrong)
        }
    }
}
