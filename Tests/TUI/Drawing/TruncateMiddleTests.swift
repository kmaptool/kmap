import XCTest

@testable import kmap

/// 2 long names that share their start still differ once cut.
final class TruncateMiddleTests: XCTestCase {
    func testTheEndIsKept() {
        let a = truncateMiddle("2026-09-06_crimean-fed-district+north-caucasus/kmap-gpsmap-67-a.img", to: 30)
        let b = truncateMiddle("2026-09-06_crimean-fed-district+north-caucasus/kmap-gpsmap-67-b.img", to: 30)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Text.cellWidth(a), 30)
        XCTAssertTrue(a.hasPrefix("2026-09-06"))
        XCTAssertTrue(a.hasSuffix("-a.img"))
        XCTAssertEqual(truncateMiddle("short", to: 30), "short")
    }
}
