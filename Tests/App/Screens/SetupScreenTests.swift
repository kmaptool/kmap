import XCTest
@testable import kmap

/// The first thing a person sees on a machine kmap was just installed on: what is
/// missing, the offer to fetch it, and the build carrying on afterwards.
///
/// Every test here is `async`, as in every other main-actor suite: on Linux XCTest calls a
/// synchronous test from a nonisolated context, and a main-actor-isolated one cannot be
/// reached from there — the whole test target stops compiling, on the generated list
/// rather than on this file.
@MainActor
final class SetupScreenTests: XCTestCase {

    private func tool(_ id: String, ready: Bool) -> ToolStatus {
        ToolStatus(id: id, name: id, detail: "", state: ready ? .ready : .missing,
                   installable: !ready)
    }

    func testOnlyWhatABuildCannotStartWithoutIsAskedFor() async {
        let tools = [tool("java", ready: false), tool("mkgmap", ready: false),
                     tool("pyhgtmap", ready: false), tool("sea", ready: false),
                     tool("bounds", ready: false)]
        // pyhgtmap and the data packs are not what stops a map being built.
        XCTAssertEqual(Toolchain.missingRequirements(in: tools).map(\.id), ["java", "mkgmap"])
    }

    func testJavaComesFirstBecauseTheOtherIsBuiltWithIt() async {
        let tools = [tool("mkgmap", ready: false), tool("java", ready: false)]
        XCTAssertEqual(Toolchain.missingRequirements(in: tools).map(\.id), ["java", "mkgmap"])
    }

    func testWhatIsAlreadyThereIsNotAskedForAgain() async {
        let tools = [tool("java", ready: true), tool("mkgmap", ready: false)]
        XCTAssertEqual(Toolchain.missingRequirements(in: tools).map(\.id), ["mkgmap"])
    }

    func testAReadyMachineIsAskedForNothing() async {
        XCTAssertTrue(Toolchain.missingRequirements(in: [tool("java", ready: true),
                                                tool("mkgmap", ready: true)]).isEmpty)
    }

    func testTheQuestionIsAskedBeforeAnythingIsInstalled() async {
        let ctx = AppContext()
        let screen = SetupScreen(missing: [tool("java", ready: false)]) { _ in .pop }
        // Cancelling leaves the screen without having touched the machine.
        XCTAssertEqual(screen.page.keys.map(\.key), ["←→", "⏎"])
        let route = screen.handle(.esc, ctx: ctx)
        if case .pop = route {} else { XCTFail("cancelling should leave the screen") }
    }

    func testTheOfferNamesEveryMissingPieceAndWhereItGoes() async {
        let ctx = AppContext()
        let screen = SetupScreen(missing: [tool("java", ready: false),
                                           tool("mkgmap", ready: false)]) { _ in .pop }
        let surface = Surface()
        surface.resize(120, 40)
        surface.clear(ctx.theme.base)
        screen.render(into: surface, rect: Rect(x: 2, y: 2, w: 116, h: 36), ctx: ctx)
        let drawn = surface.compose()
        XCTAssertTrue(drawn.contains("java"), "the missing pieces are named")
        XCTAssertTrue(drawn.contains("mkgmap"), "the missing pieces are named")
        // Where they go is part of the question, since it is the machine being changed.
        XCTAssertTrue(drawn.contains(Paths.root.lastPathComponent), "and where they land")
        XCTAssertTrue(drawn.contains("Java"), "and why they are needed")
    }
}
