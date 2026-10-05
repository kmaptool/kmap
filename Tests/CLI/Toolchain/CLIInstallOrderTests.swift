import XCTest

@testable import kmap

final class CLIInstallOrderTests: XCTestCase {
    func testAToolComesAfterWhatItNeeds() {
        XCTAssertEqual(CLI.prerequisitesFirst(["mkgmap", "unzip"]), ["unzip", "mkgmap"])
        XCTAssertEqual(
            CLI.prerequisitesFirst(["mkgmap-patch", "java", "mkgmap", "unzip"]),
            ["java", "unzip", "mkgmap", "mkgmap-patch"]
        )
        // What is not being installed is not added.
        XCTAssertEqual(CLI.prerequisitesFirst(["mkgmap", "pyhgtmap"]), ["mkgmap", "pyhgtmap"])
    }
}
