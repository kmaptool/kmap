import XCTest

@testable import kmap

/// What `kmap recover` says where it has no region left to suggest.
final class CLIRecoverSuggestTests: XCTestCase {
    /// Extracts in the cache that hold the map and gave nothing are named as such: with
    /// none held, nothing is said about extracts kmap holds.
    func testExtractsAreBlamedOnlyWhereSomeAreHeld() {
        XCTAssertTrue(CLI.nothingToSuggest(held: true).contains("the extracts kmap holds"))
        XCTAssertTrue(CLI.nothingToSuggest(held: true).contains("--extract"))
        XCTAssertFalse(CLI.nothingToSuggest(held: false).contains("holds"))
        XCTAssertTrue(CLI.nothingToSuggest(held: false).contains("no region kmap can download"))
    }
}
