import XCTest
@testable import kmap

/// Where the catalogue is written and read back from.
final class HideableCatalogueTests: XCTestCase {

    /// The base style is built in a staging directory and swapped into place, so the
    /// catalogue lands beside the points it was read from, not at the shared path.
    func testTheCatalogueIsWrittenBesideThePointsItWasReadFrom() {
        // The pure half of `record`: recording would replace the catalogue other tests read.
        let points = URL(fileURLWithPath: "/styles/.base-build-1a2b/points")
        XCTAssertEqual(HideableCatalogue.destination(besidePoints: points).path,
                       "/styles/.base-build-1a2b/hideable.txt")
        XCTAssertNotEqual(HideableCatalogue.destination(besidePoints: points),
                          HideableCatalogue.url, "not the shared path the swap removes")
    }
}
