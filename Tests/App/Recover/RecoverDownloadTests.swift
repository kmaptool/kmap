import XCTest

@testable import kmap

@MainActor
final class RecoverDownloadTests: XCTestCase {
    /// Stopped while it waits for a cache clear, the download says so and lets the screen go.
    func testStoppingWhileACacheClearRunsCancels() async throws {
        let ctx = AppContext()
        Paths.ensure(Paths.locks)
        let clear = try XCTUnwrap(HeldLock(trying: CacheClearing.inUseLock(elevation: false)))
        XCTAssertEqual(clear.isHeld, true)
        let screen = RecoverScreen(img: URL(fileURLWithPath: "/tmp/x.img"), typ: URL(fileURLWithPath: "/tmp/r18.txt"))
        let box = BBox(minLon: 40, minLat: 40, maxLon: 41, maxLat: 41)
        screen.download([Region(id: "zz-test", name: "ZZ", parentID: nil, pbfURL: nil, bbox: box, boxes: [box])], ctx)
        _ = screen.handle(.esc, ctx: ctx)
        for _ in 0..<100 where screen.phase == .downloading { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(screen.phase, .cancelled)
        withExtendedLifetime(clear) {}
    }
}
