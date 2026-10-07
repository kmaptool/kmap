import XCTest

@testable import kmap

/// What a screen says after a key (a refusal, a question, a failed save) is drawn on
/// ordinary terminal sizes, not left under a full list.
@MainActor
final class MessagesStayVisibleTests: XCTestCase {
    private var ctx: AppContext!
    private var style: MapStyle!

    override func setUpWithError() throws {
        try MainActor.assumeIsolated {
            ctx = AppContext()
            let library = try TypLibrary.adopt(
                source: TypFixture.source,
                named: "zz-visible-\(UUID().uuidString.prefix(8))"
            )
            addTeardownBlock { try? TypLibrary.delete(library) }
            style = try XCTUnwrap(StyleCatalog.libraryStyle(at: library))
        }
    }

    private func drawn(_ screen: Screen, _ width: Int, _ height: Int) -> String {
        let surface = Surface()
        surface.resize(width, height)
        surface.clear(ctx.theme.base)
        screen.tick(ctx)
        let rect = Rect(x: 2, y: 2, w: width - 4, h: height - 4)
        screen.render(into: surface, rect: rect, ctx: ctx)
        screen.renderOverlay(into: surface, rect: rect, ctx: ctx)
        return surface.asText()
    }

    private func type(_ text: String, into screen: Screen) {
        for character in text { _ = screen.handle(.char(character), ctx: ctx) }
    }

    func testASettingsRefusalIsDrawn() async {
        for (width, height) in [(80, 24), (80, 26), (110, 40)] {
            let screen = SettingsScreen()
            _ = drawn(screen, width, height)
            let fields = screen.fields(ctx)
            for _ in 0..<(fields.firstIndex(of: .work) ?? 0) { _ = screen.handle(.down, ctx: ctx) }
            _ = screen.handle(.enter, ctx: ctx)
            for _ in 0..<300 { _ = screen.handle(.backspace, ctx: ctx) }
            type("relative/dir", into: screen)
            _ = screen.handle(.enter, ctx: ctx)
            XCTAssertTrue(drawn(screen, width, height).contains("not a full path"), "\(width)x\(height)")
        }
    }

    /// A question whose key is not on screen must not be live: it is drawn, whole.
    func testTheToolchainsQuestionIsDrawnWhole() async {
        var tools: [ToolStatus] = []
        for id in ["java", "mkgmap", "mkgmap-patch", "sea", "bounds", "python", "pyhgtmap", "unzip"] {
            var tool = ToolStatus(
                id: id,
                name: id,
                detail: "used for this",
                state: .ready,
                installable: true,
                isOptional: false
            )
            tool.removable = true
            tools.append(tool)
        }
        ctx.useForTesting(tools: tools)
        ctx.useForTesting(packNews: [:])
        for height in 20...44 {
            for width in [80, 110, 140] {
                let screen = ToolchainScreen()
                _ = drawn(screen, width, height)
                _ = screen.handle(.down, ctx: ctx)
                _ = screen.handle(.down, ctx: ctx)
                _ = screen.handle(.char("x"), ctx: ctx)
                XCTAssertTrue(drawn(screen, width, height).contains("press y"), "\(width)x\(height)")
            }
        }
    }

    func testARecoverSaveFailureIsDrawnUnderALongList() async {
        for (width, height) in [(80, 24), (110, 40)] {
            let screen = RecoverScreen(
                img: URL(fileURLWithPath: "/tmp/x.img"),
                typ: URL(fileURLWithPath: "/nonexistent-dir/r18.txt")
            )
            var report = StyleRecovery.Report()
            report.style = "; recovered\n"
            for i in 0..<60 {
                report.outcomes["L\(i)"] = StyleRecovery.Outcome(
                    kind: .line,
                    type: i,
                    witnesses: 1,
                    elements: 1,
                    unmatched: 0,
                    ambiguous: 0,
                    meaning: "highway=x\(i)",
                    status: .noRule
                )
            }
            screen.report = report
            screen.phase = .done
            // Asked first, as any overwrite of a style is: confirmed.
            _ = screen.handle(.enter, ctx: ctx)
            XCTAssertNotNil(screen.asking)
            _ = screen.handle(.right, ctx: ctx)
            _ = screen.handle(.enter, ctx: ctx)
            let said = String(screen.message?.prefix(15) ?? "@@")
            XCTAssertTrue(drawn(screen, width, height).contains(said), "\(width)x\(height)")
        }
    }

    func testATypeEditorRefusalIsDrawnWithAFullList() async throws {
        for (width, height) in [(80, 24), (110, 40)] {
            let screen = TypeEditScreen(style: style, kind: .point, code: TypFixture.iconCode, onEdited: {})
            _ = drawn(screen, width, height)
            let colour = try XCTUnwrap(
                screen.fields.firstIndex { if case .colourPair = $0 { return true } else { return false } }
            )
            screen.list.selected = colour
            _ = screen.handle(.enter, ctx: ctx)
            for _ in 0..<20 { _ = screen.handle(.backspace, ctx: ctx) }
            type("zzz", into: screen)
            _ = screen.handle(.enter, ctx: ctx)
            let said = String(screen.message?.prefix(15) ?? "@@")
            XCTAssertTrue(drawn(screen, width, height).contains(said), "\(width)x\(height)")
        }
    }

    func testATypeBrowserNoticeShowsWithThePreviewOpen() async {
        let screen = TypeBrowserScreen(document: StyleDocument.load(style), kind: .polygon)
        _ = drawn(screen, 110, 40)
        for _ in 0..<50 where screen.selectedRow?.isStyled != true { _ = screen.handle(.down, ctx: ctx) }
        _ = screen.handle(.char("p"), ctx: ctx)
        _ = screen.handle(.char("a"), ctx: ctx)
        let said = String(screen.notice.text?.prefix(15) ?? "@@")
        XCTAssertTrue(drawn(screen, 110, 40).contains(said))
    }

    /// A palette longer than the terminal follows the colour painted with.
    func testTheColourPaintedWithIsInSight() async throws {
        let screen = try XCTUnwrap(
            PixelEditorScreen(style: style, kind: .point, code: TypFixture.iconCode, onSaved: {})
        )
        _ = drawn(screen, 80, 24)
        _ = screen.handle(.tab, ctx: ctx)
        for _ in 0..<30 { _ = screen.handle(.down, ctx: ctx) }
        XCTAssertEqual(screen.selected, screen.shown.palette.count - 1)
        let colour = try XCTUnwrap(screen.shown.palette.last?.colour ?? t("none"))
        XCTAssertTrue(drawn(screen, 80, 24).contains(colour))
        XCTAssertGreaterThanOrEqual(screen.selected, screen.paletteScroll)
        XCTAssertLessThan(screen.selected, screen.paletteScroll + screen.paletteShown)
    }

    /// A finished recovery not saved is not left on 1 key, Esc or ^C.
    func testAnUnsavedRecoveryIsNotLeftUnasked() async {
        let screen = RecoverScreen(img: URL(fileURLWithPath: "/tmp/x.img"), typ: URL(fileURLWithPath: "/tmp/r18.txt"))
        var report = StyleRecovery.Report()
        report.style = "; recovered\n"
        screen.report = report
        screen.phase = .done
        if case .pop = screen.handle(.esc, ctx: ctx) { XCTFail("left on Esc") }
        XCTAssertNotNil(screen.asking)
        _ = screen.handle(.esc, ctx: ctx)
        XCTAssertNil(screen.asking, "Esc on the question stays")
        if case .quit = screen.handle(.ctrl("c"), ctx: ctx) { XCTFail("quit on ^C") }
        _ = screen.handle(.right, ctx: ctx)
        if case .quit = screen.handle(.enter, ctx: ctx) {} else { XCTFail("a yes leaves") }
    }
}
