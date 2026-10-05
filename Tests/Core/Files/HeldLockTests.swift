import XCTest

@testable import kmap

final class HeldLockTests: XCTestCase {
    func testASecondHolderIsTurnedAwayUntilTheFirstLetsGo() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kmap-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var first = HeldLock(trying: file)
        XCTAssertNotNil(first)
        XCTAssertNil(HeldLock(trying: file), "taken twice at once")
        first = nil
        XCTAssertNotNil(HeldLock(trying: file), "not given back")
    }

    func testAFileThatCannotBeMadeLetsTheWorkGoAhead() {
        let nowhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-missing-\(UUID().uuidString)/x/lock")
        XCTAssertNotNil(HeldLock(trying: nowhere))
    }
}
