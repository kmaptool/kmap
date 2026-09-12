import XCTest
@testable import kmap

/// Installing from the toolchain screen: several at once, each in its own row, one that
/// overlaps another waiting its turn, and ^C stopping the lot, downloads included.
///
/// The tool list is the test's own and the installer a stand-in, so nothing here depends
/// on what this machine has installed or on a network.
@MainActor
final class ToolchainInstallTests: XCTestCase {

    private var ctx: AppContext!
    private var screen: ToolchainScreen!
    private var installs: InstallStandIn!
    private var cursor = 0

    private func tool(_ id: String, name: String? = nil, ready: Bool = false,
                      optional: Bool = false) -> ToolStatus {
        ToolStatus(id: id, name: name ?? id, detail: "", state: ready ? .ready : .missing,
                   installable: true, isOptional: optional)
    }

    override func setUp() async throws {
        ctx = AppContext()
        ctx.useForTesting(tools: [tool("mkgmap"), tool("mkgmap-patch", name: "seam patch"),
                                  tool("sea"), tool("bounds", ready: true),
                                  tool("pyhgtmap", optional: true)])
        ctx.useForTesting(packNews: [:])
        installs = InstallStandIn()
        screen = ToolchainScreen()
        screen.useForTesting(installer: installs.installer)
        cursor = 0
        _ = drawn()
    }

    override func tearDown() async throws {
        // Whatever a failed assertion left running is stopped before the next test.
        _ = screen.handle(.ctrl("c"), ctx: ctx)
        _ = await settles { self.screen.runningForTesting.isEmpty }
    }

    // MARK: Driving the screen

    private func drawn() -> String {
        let surface = Surface()
        surface.resize(110, 40)
        surface.clear(ctx.theme.base)
        screen.tick(ctx)
        screen.render(into: surface, rect: Rect(x: 2, y: 2, w: 106, h: 36), ctx: ctx)
        return surface.compose()
    }

    private func select(_ id: String) throws {
        let target = try XCTUnwrap(ctx.tools.firstIndex { $0.id == id })
        let count = ctx.tools.count
        for _ in 0..<((target - cursor + count) % count) { _ = screen.handle(.down, ctx: ctx) }
        cursor = target
    }

    private func press(_ key: KeyEvent, on id: String) throws -> Route {
        try select(id)
        return screen.handle(key, ctx: ctx)
    }

    private func running() -> [String] { screen.runningForTesting }

    /// A download 48% in, reported the way `Downloader` reports one.
    private func halfway(_ id: String) {
        let download = DownloadProgress()
        download.begin(total: 2000, partTotals: [2000], alreadyOnDisk: 0)
        download.advance(part: 0, by: 960)
        screen.progressForTesting(id)?.downloading("downloading \(id)", download)
    }

    // MARK: One install

    func testEnterStartsAnInstallAndItsRowShowsTheBar() async throws {
        _ = try press(.enter, on: "sea")
        XCTAssertEqual(running(), ["sea"])
        await expectSettled { self.installs.startedIDs == ["sea"] }

        halfway("sea")
        let shown = drawn()
        XCTAssertTrue(shown.contains("downloading sea"), "the stage is on the row")
        XCTAssertTrue(shown.contains("960 B / 2 kB"), "and the bytes")
        XCTAssertTrue(shown.contains("48%"), "and the bar's percentage")
        XCTAssertTrue(shown.contains(String(Glyph.drawable(Glyph.barFill))), "and the bar itself")
        XCTAssertTrue(screen.page.keys.contains { $0.key == "^C" }, "the footer offers stop")
    }

    func testAStepWithNoNumberDrawsAnIndeterminateBar() async throws {
        _ = try press(.enter, on: "sea")
        screen.progressForTesting("sea")?.step("unpacking")
        let shown = drawn()
        XCTAssertTrue(shown.contains("unpacking"))
        XCTAssertFalse(shown.contains("%"), "no number, no percentage")
    }

    func testEnterOnARunningRowStartsNothingTwice() async throws {
        _ = try press(.enter, on: "sea")
        _ = try press(.enter, on: "sea")
        XCTAssertEqual(screen.messageForTesting, t("%@ is still installing", "sea"))
        await expectSettled { self.installs.startedIDs == ["sea"] }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(installs.timesStarted("sea"), 1)
    }

    func testAFinishedInstallGivesItsRowBack() async throws {
        _ = try press(.enter, on: "sea")
        installs.release("sea")
        await expectSettled { self.running().isEmpty }
        XCTAssertFalse(screen.page.keys.contains { $0.key == "^C" })
        XCTAssertTrue(drawn().contains(t("%@ installed", "sea")), "the log says so")
    }

    // MARK: Several at once

    func testTwoIndependentInstallsRunSideBySide() async throws {
        _ = try press(.enter, on: "sea")
        _ = try press(.enter, on: "mkgmap")
        XCTAssertEqual(running(), ["mkgmap", "sea"])
        await expectSettled { Set(self.installs.startedIDs) == ["sea", "mkgmap"] }
        halfway("sea")
        screen.progressForTesting("mkgmap")?.step("looking up the latest release")
        let shown = drawn()
        XCTAssertTrue(shown.contains("48%"), "each row draws its own")
        XCTAssertTrue(shown.contains("looking up the latest release"))
    }

    func testAnInstallWaitsForTheOneItOverlaps() async throws {
        _ = try press(.enter, on: "mkgmap")
        _ = try press(.enter, on: "mkgmap-patch")
        XCTAssertEqual(running(), ["mkgmap"], "the patch would fetch mkgmap as well")
        XCTAssertEqual(screen.queuedForTesting, ["mkgmap-patch"])
        XCTAssertEqual(screen.messageForTesting, t("waiting for %@", "mkgmap"))
        XCTAssertTrue(drawn().contains(t("waiting for %@", "mkgmap")), "said on its row")

        installs.release("mkgmap")
        await expectSettled { self.running() == ["mkgmap-patch"] }
        XCTAssertTrue(screen.queuedForTesting.isEmpty)
        XCTAssertEqual(installs.startedIDs, ["mkgmap", "mkgmap-patch"])
    }

    func testTheOtherWayRoundWaitsToo() async throws {
        _ = try press(.enter, on: "mkgmap-patch")
        _ = try press(.enter, on: "mkgmap")
        XCTAssertEqual(running(), ["mkgmap-patch"])
        XCTAssertEqual(screen.queuedForTesting, ["mkgmap"])
        XCTAssertEqual(screen.messageForTesting, t("waiting for %@", "seam patch"))
    }

    func testEnterOnAWaitingRowLeavesItWaiting() async throws {
        _ = try press(.enter, on: "mkgmap")
        _ = try press(.enter, on: "mkgmap-patch")
        _ = try press(.enter, on: "mkgmap-patch")
        XCTAssertEqual(screen.queuedForTesting, ["mkgmap-patch"], "queued once")
        XCTAssertEqual(screen.messageForTesting, t("waiting for %@", "mkgmap"))
    }

    func testAFailedInstallFreesItsRowAndTheQueueMovesOn() async throws {
        _ = try press(.enter, on: "mkgmap")
        _ = try press(.enter, on: "mkgmap-patch")
        installs.fail("mkgmap")
        // The patch fetches mkgmap itself, so it goes ahead rather than waiting forever.
        await expectSettled { self.running() == ["mkgmap-patch"] }
        XCTAssertTrue(drawn().contains("did not work"), "the failure is in the log")
    }

    func testInstallAllStartsEverythingMissingAtOnce() async throws {
        _ = screen.handle(.char("a"), ctx: ctx)
        XCTAssertEqual(running(), ["mkgmap", "sea"], "what a build needs, in parallel")
        XCTAssertEqual(screen.queuedForTesting, ["mkgmap-patch"], "behind mkgmap")
        await expectSettled { Set(self.installs.startedIDs) == ["mkgmap", "sea"] }
        XCTAssertEqual(installs.timesStarted("bounds"), 0, "already installed")
        XCTAssertEqual(installs.timesStarted("pyhgtmap"), 0, "optional")
    }

    func testInstallAllWithNothingMissingSaysSo() async throws {
        ctx.useForTesting(tools: [tool("bounds", ready: true), tool("pyhgtmap", optional: true)])
        _ = screen.handle(.char("a"), ctx: ctx)
        XCTAssertTrue(running().isEmpty)
        XCTAssertEqual(screen.messageForTesting, t("nothing left to install"))
    }

    // MARK: Stopping

    func testControlCStopsEverythingRunningAndQueued() async throws {
        _ = try press(.enter, on: "sea")
        _ = try press(.enter, on: "mkgmap")
        _ = try press(.enter, on: "mkgmap-patch")
        await expectSettled { self.installs.startedIDs.count == 2 }

        let route = screen.handle(.ctrl("c"), ctx: ctx)
        if case .none = route {} else { XCTFail("stopping stays on the screen") }
        await expectSettled { self.running().isEmpty }
        XCTAssertEqual(Set(installs.cancelledIDs), ["sea", "mkgmap"],
                       "each install's task was cancelled, not only its process")
        XCTAssertTrue(screen.queuedForTesting.isEmpty)
        XCTAssertEqual(installs.timesStarted("mkgmap-patch"), 0, "never started")
        XCTAssertTrue(drawn().contains(t("stopped")))

        // Nothing stale holds the patch back afterwards.
        _ = try press(.enter, on: "mkgmap-patch")
        XCTAssertEqual(running(), ["mkgmap-patch"])
    }

    func testControlCWithNothingRunningQuits() async throws {
        let route = screen.handle(.ctrl("c"), ctx: ctx)
        if case .quit = route {} else { XCTFail("^C on an idle screen quits, as everywhere") }
    }

    func testEscapeIsRefusedWhileAnythingInstalls() async throws {
        _ = try press(.enter, on: "sea")
        let held = screen.handle(.esc, ctx: ctx)
        if case .none = held {} else { XCTFail("leaving would orphan the download") }
        XCTAssertEqual(screen.messageForTesting, t("still installing: ^C stops everything"))

        installs.release("sea")
        await expectSettled { self.running().isEmpty }
        let left = screen.handle(.esc, ctx: ctx)
        if case .pop = left {} else { XCTFail("free to leave once it is done") }
    }

    func testRemovingOrUpdatingARunningToolIsRefused() async throws {
        _ = try press(.enter, on: "sea")
        _ = try press(.char("x"), on: "sea")
        XCTAssertEqual(screen.messageForTesting, t("%@ is still installing", "sea"))
        _ = try press(.char("u"), on: "sea")
        XCTAssertEqual(screen.messageForTesting, t("%@ is still installing", "sea"))
        XCTAssertEqual(running(), ["sea"])
    }
}
