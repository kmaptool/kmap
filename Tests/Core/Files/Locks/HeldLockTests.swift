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

    /// Shared holders keep out one that would hold it alone, and are kept out by one.
    func testSharedHoldersKeepOutOnlyOneAlone() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kmap-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var first = HeldLock(trying: file, shared: true)
        var second = HeldLock(trying: file, shared: true)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "shared twice at once")
        XCTAssertNil(HeldLock(trying: file), "alone while shared")
        first = nil
        XCTAssertNil(HeldLock(trying: file), "alone while 1 still shares")
        second = nil
        let alone = HeldLock(trying: file)
        XCTAssertNotNil(alone)
        XCTAssertNil(HeldLock(trying: file, shared: true), "shared while alone")
        withExtendedLifetime(alone) {}
    }

    /// A lock file that opens only to read is still held and seen held; one that will not
    /// open at all is refused, which a sweep of old locks takes for a leftover.
    func testALockFileOfAnotherUsersIsHeldOrRefusedByItsRights() throws {
        #if os(Windows)
        throw XCTSkip("rights are POSIX bits here")
        #else
        try XCTSkipIf(getuid() == 0, "root opens anything")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "kmap-locks-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let readable = folder.appendingPathComponent("readable.lock")
        let closed = folder.appendingPathComponent("closed.lock")
        for (file, mode) in [(readable, 0o444), (closed, 0o000)] {
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        let held = try XCTUnwrap(HeldLock(trying: readable))
        XCTAssertTrue(held.isHeld)
        XCTAssertNil(HeldLock(trying: readable), "a hold through a read is seen")
        withExtendedLifetime(held) {}
        let shut = try XCTUnwrap(HeldLock(trying: closed))
        XCTAssertFalse(shut.isHeld)
        XCTAssertTrue(shut.refused)
        #endif
    }

    func testAFileThatCannotBeMadeLetsTheWorkGoAhead() {
        let nowhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-missing-\(UUID().uuidString)/x/lock")
        let unlocked = try? XCTUnwrap(HeldLock(trying: nowhere))
        XCTAssertNotNil(unlocked)
        XCTAssertEqual(unlocked?.isHeld, false, "gone ahead, not held")
    }
}
