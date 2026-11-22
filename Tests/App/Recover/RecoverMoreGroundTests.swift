import XCTest

@testable import kmap

/// After a run that went through and left codes unsure, the region that may settle the
/// most of them is offered; whatever becomes of that, the result already read stays up.
/// Every test is `async`: Linux's generated test list cannot name a synchronous
/// main-actor method.
@MainActor
final class RecoverMoreGroundTests: XCTestCase {
    private struct Broken: Error {}

    private func screen() -> RecoverScreen {
        RecoverScreen(img: URL(fileURLWithPath: "/tmp/x.img"), typ: URL(fileURLWithPath: "/tmp/r18.txt"))
    }

    /// A recovered style, read on `share` of the map.
    private func report(share: Double) -> StyleRecovery.Report {
        var report = StyleRecovery.Report()
        report.style = "; recovered\n"
        report.share = share
        return report
    }

    private var region: Region {
        let box = BBox(minLon: 40, minLat: 40, maxLon: 41, maxLat: 41)
        return Region(id: "zz-test", name: "ZZ", parentID: nil, pbfURL: nil, bbox: box, boxes: [box])
    }

    /// A run that left 9 of 189 codes unsure.
    private let left = StyleRecovery.Remainder(codes: 189, tooFew: 5, never: 3, mixed: 1, drawn: [])

    private var thin: StyleRecovery.Report {
        var out = report(share: 0.4)
        out.remainder = left
        return out
    }

    func testTheQuestionSaysWhyAndWhat() async throws {
        let screen = screen()
        screen.present(region, size: 846 << 20, settling: 7, of: left)
        let more = try XCTUnwrap(screen.offering)
        XCTAssertEqual(more.dialog.title, t("Download 1 more region?"))
        for number in ["9", "189", "7"] { XCTAssertTrue(more.dialog.body[0].contains(number), more.dialog.body[0]) }
        XCTAssertEqual(more.dialog.detail.first?.label, "ZZ")
        XCTAssertEqual(more.dialog.detail.first?.value, "≈ " + Fmt.bytes(846 << 20))
        XCTAssertEqual(more.subject.map(\.id), ["zz-test"])

        let first = self.screen()
        first.present([(region, nil)])
        XCTAssertEqual(first.offering?.dialog.title, t("Download a region?"))
        XCTAssertEqual(first.offering?.dialog.detail.first?.value, "…", "the server did not say")

        // What a refused run needs may be several regions: asked about in 1 question.
        let box = BBox(minLon: 42, minLat: 40, maxLon: 43, maxLat: 41)
        let other = Region(id: "yy-test", name: "YY", parentID: nil, pbfURL: nil, bbox: box, boxes: [box])
        let both = self.screen()
        both.present([(region, 846 << 20), (other, 743 << 20)])
        XCTAssertEqual(both.offering?.dialog.title, tn("Download %d region(s)?", 2))
        XCTAssertEqual(both.offering?.dialog.detail.map(\.label), ["ZZ", "YY"])
        XCTAssertEqual(both.offering?.subject.map(\.id), ["zz-test", "yy-test"])
    }

    /// A run that did not look over the rest of the map has nothing to ask about.
    func testARunThatDidNotLookOffersNoMore() async {
        let more = await RecoverScreen.groundToAdd(after: report(share: 0.4), index: RegionIndex())
        XCTAssertNil(more?.region.id)
    }

    /// A run started after one that went through shows its stages from the first.
    func testARerunStartsItsStagesOver() async {
        let screen = screen()
        screen.progress.move(to: .deriving)
        screen.start(AppContext())
        XCTAssertEqual(screen.progress.snapshot.stage, .preparing)
        _ = screen.handle(.esc, ctx: AppContext())
    }

    func testDecliningMoreGroundKeepsTheResult() async {
        let ctx = AppContext()
        let screen = screen()
        screen.report = thin
        screen.phase = .done
        screen.present(region, size: nil, settling: 7, of: left)
        // The cursor starts on "not now".
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertNil(screen.offering)
        XCTAssertEqual(screen.phase, .done)
        XCTAssertTrue(screen.recovered)
        // The result is saved as any other: Enter asks about the overwrite.
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertNotNil(screen.asking)
    }

    func testDecliningTheFirstRegionCancels() async {
        let ctx = AppContext()
        let screen = screen()
        screen.present([(region, nil)])
        _ = screen.handle(.esc, ctx: ctx)
        XCTAssertNil(screen.offering)
        XCTAssertEqual(screen.phase, .cancelled)
    }

    /// The download of 1 more region stopped: back to the result, not to a cancelled screen.
    func testAStoppedDownloadOfMoreGroundKeepsTheResult() async throws {
        let ctx = AppContext()
        Paths.ensure(Paths.locks)
        let clear = try XCTUnwrap(HeldLock(trying: CacheClearing.inUseLock(elevation: false)))
        let screen = screen()
        screen.report = thin
        screen.phase = .done
        screen.present(region, size: nil, settling: 7, of: left)
        _ = screen.handle(.right, ctx: ctx)
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertEqual(screen.phase, .downloading)
        _ = screen.handle(.esc, ctx: ctx)
        for _ in 0..<100 where screen.phase == .downloading { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(screen.phase, .done)
        XCTAssertTrue(screen.recovered)
        withExtendedLifetime(clear) {}
    }

    func testATroubleAfterAResultIsSaidBesideIt() async {
        let screen = screen()
        screen.report = report(share: 0.4)
        screen.fail(Broken())
        XCTAssertEqual(screen.phase, .done)
        XCTAssertNotNil(screen.message)
        XCTAssertTrue(screen.messageIsError)
        XCTAssertNil(screen.failure)
        // Said in words of the screen's own, the same holds.
        screen.fail(saying: "no region left")
        XCTAssertEqual(screen.phase, .done)
        XCTAssertEqual(screen.message, "no region left")
        XCTAssertTrue(screen.messageIsError)

        let first = self.screen()
        first.fail(Broken())
        XCTAssertEqual(first.phase, .failed)
        XCTAssertNotNil(first.failure)
    }
}
