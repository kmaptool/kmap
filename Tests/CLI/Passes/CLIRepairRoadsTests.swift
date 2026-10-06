import XCTest

@testable import kmap

final class CLIRepairRoadsTests: XCTestCase {
    /// A reach past a build's own range is refused before anything is read: its search
    /// grid grows with its square and joins nothing more.
    func testALimitPastABuildsRangeIsRefused() {
        let missing = NSTemporaryDirectory() + "no-such-\(UUID().uuidString).osm.pbf"
        for limit in ["1e30", "51", "-1", "much"] {
            XCTAssertEqual(
                CLI.repairRoads([missing, missing + ".out", "--limit=\(limit)"]),
                CLIOutput.Exit.refused,
                limit
            )
        }
    }
}
