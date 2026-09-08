import XCTest
@testable import kmap

/// The rights question gates the import: ⏎ on a candidate copies nothing, and the copy is
/// made only after the confirming answer. `@MainActor` because the screens are, and every
/// test is `async` because Linux's generated test list cannot name a synchronous
/// main-actor method.
@MainActor
final class ImportConsentTests: XCTestCase {

    private var ctx: AppContext!

    override func setUp() {
        // On Linux `setUp` is nonisolated, so the isolation has to be stated to reach
        // this class's own properties.
        MainActor.assumeIsolated {
            super.setUp()
            ctx = AppContext()
        }
    }

    private func frame(_ screen: Screen, width: Int = 110, height: Int = 34) -> String {
        let s = Surface()
        s.resize(width, height)
        s.clear(ctx.theme.base)
        screen.tick(ctx)
        screen.render(into: s, rect: Rect(x: 2, y: 1, w: width - 4, h: height - 2), ctx: ctx)
        return s.compose()
    }

    /// The screen in path mode with `path` typed in, which depends on nothing plugged into
    /// this machine. A lone TYP is asked about itself first; `pastTheFirstQuestion` answers
    /// that one, leaving the rights question on screen.
    private func screenAsking(_ path: String,
                              pastTheFirstQuestion: Bool = true) -> ImportTypScreen {
        let screen = ImportTypScreen(onImported: {})
        _ = frame(screen)
        _ = screen.handle(.tab, ctx: ctx)
        for c in path { _ = screen.handle(.char(c), ctx: ctx) }
        _ = screen.handle(.enter, ctx: ctx)
        if pastTheFirstQuestion, !ImgContainer.isImg(URL(fileURLWithPath: path)) {
            _ = screen.handle(.right, ctx: ctx)
            _ = screen.handle(.enter, ctx: ctx)
        }
        return screen
    }

    // MARK: The question a lone TYP gets first

    func testALoneTypIsToldWhatTakingItAloneCosts() async {
        let screen = screenAsking("/tmp/does-not-exist.typ", pastTheFirstQuestion: false)
        let drawn = frame(screen)
        XCTAssertTrue(drawn.contains(t("Only the drawing").uppercased()),
                      "the first question is about the file, not about copyright")
        XCTAssertFalse(drawn.contains("IMPORTANT"), "the rights question comes after it")
    }

    func testDecliningThatQuestionImportsNothing() async {
        let screen = screenAsking("/tmp/does-not-exist.typ", pastTheFirstQuestion: false)
        _ = screen.handle(.esc, ctx: ctx)
        let drawn = frame(screen)
        XCTAssertTrue(drawn.contains(t("nothing was imported")))
        XCTAssertFalse(drawn.contains("IMPORTANT"), "and the rights question never came up")
    }

    func testAgreeingToItLeadsToTheRightsQuestion() async {
        let screen = screenAsking("/tmp/does-not-exist.typ")
        XCTAssertTrue(frame(screen).contains("IMPORTANT"))
    }

    func testEnterAsksBeforeItTakesAnything() async {
        let screen = screenAsking("/tmp/does-not-exist.typ")
        let drawn = frame(screen)
        XCTAssertTrue(drawn.contains("IMPORTANT"), "⏎ has to put the question up")
        XCTAssertTrue(drawn.contains("does-not-exist.typ"),
                      "and name the file it is about")
        // Not the import's own error, which is what would be on screen had it gone ahead.
        XCTAssertFalse(drawn.contains("no such file"))
    }

    func testTheFooterBelongsToTheDialogWhileItIsUp() async {
        let screen = screenAsking("/tmp/does-not-exist.typ")
        XCTAssertTrue(screen.footerHints.contains { $0.key == "←→" })
        XCTAssertFalse(screen.footerHints.contains { $0.label == t("type a path") })
    }

    func testCancellingImportsNothing() async {
        let screen = screenAsking("/tmp/does-not-exist.typ")
        _ = screen.handle(.esc, ctx: ctx)
        let drawn = frame(screen)
        XCTAssertFalse(drawn.contains("IMPORTANT"), "the question is gone")
        XCTAssertTrue(drawn.contains(t("nothing was imported")))
        XCTAssertFalse(drawn.contains("no such file"), "and nothing was attempted")
    }

    func testEnterOnItsOwnCancelsRatherThanImporting() async {
        // The cursor starts on the cancelling answer.
        let screen = screenAsking("/tmp/does-not-exist.typ")
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertTrue(frame(screen).contains(t("nothing was imported")))
    }

    func testConfirmingRunsTheImport() async {
        // The path cannot be imported, on purpose: the error is the proof that the import
        // ran, and the real library is left untouched.
        let screen = screenAsking("/tmp/does-not-exist.typ")
        _ = screen.handle(.right, ctx: ctx)
        _ = screen.handle(.enter, ctx: ctx)
        let drawn = frame(screen)
        XCTAssertFalse(drawn.contains("IMPORTANT"))
        XCTAssertTrue(drawn.contains("does-not-exist.typ"),
                      "the import ran and said what it could not find")
    }

    func testTheQuestionIsAskedInTheLanguageOnScreen() async {
        let was = L10n.current
        defer { L10n.use(was) }

        L10n.use(.ru)
        let russian = screenAsking("/tmp/a.typ")
        XCTAssertTrue(frame(russian).contains("ВАЖНО"))
        _ = russian.handle(.right, ctx: ctx)
        XCTAssertTrue(russian.footerHints.contains { $0.label == "подтверждаю" },
                      "the confirming answer has to be readable to whoever is agreeing")

        L10n.use(.en)
        let english = screenAsking("/tmp/a.typ")
        XCTAssertTrue(frame(english).contains("IMPORTANT"))
        _ = english.handle(.right, ctx: ctx)
        XCTAssertTrue(english.footerHints.contains { $0.label == "I confirm" })
    }

    func testItIsAskedAgainForTheNextFile() async {
        // One answer covers one file.
        let screen = screenAsking("/tmp/does-not-exist.typ")
        _ = screen.handle(.esc, ctx: ctx)
        for _ in 0..<20 { _ = screen.handle(.backspace, ctx: ctx) }
        for c in "/tmp/another.typ" { _ = screen.handle(.char(c), ctx: ctx) }
        _ = screen.handle(.enter, ctx: ctx)
        // Both questions again, in order.
        XCTAssertTrue(frame(screen).contains(t("Only the drawing").uppercased()))
        _ = screen.handle(.right, ctx: ctx)
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertTrue(frame(screen).contains("IMPORTANT"))
    }

    // MARK: A file already held

    /// A file the library already holds is refused without a rights question, and the
    /// refusal names the entry it is already in.
    func testAFileAlreadyHeldIsRefusedRatherThanCopiedAgain() async throws {
        // Both folders: an original is not a style, but the import list compares
        // against it.
        let originals = TypLibrary.originalsDirectory()
        let before = Set((TypLibrary.contents() + TypLibrary.contents(in: originals))
            .map(\.lastPathComponent))
        addTeardownBlock {
            for url in TypLibrary.contents() + TypLibrary.contents(in: originals)
            where !before.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // A binary taken into the library the ordinary way, so it has an original beside it.
        var bytes = [UInt8](repeating: 0, count: 0x60)
        bytes[0] = 0x5B
        for (i, b) in Array("GARMIN TYP".utf8).enumerated() { bytes[2 + i] = b }
        bytes[0x2F] = 0x2B
        bytes[0x31] = 0x01
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zz-consent-\(UUID().uuidString.prefix(6)).typ")
        try Data(bytes).write(to: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        let taken = try TypLibrary.take(at: source)

        let held = Set(TypLibrary.contents())
        let screen = screenAsking(source.path)
        let drawn = frame(screen)

        XCTAssertFalse(drawn.contains("IMPORTANT"),
                       "nothing to ask about — it is already here")
        XCTAssertTrue(drawn.contains(taken.url.deletingPathExtension().lastPathComponent),
                      "the refusal names the entry it is already in")
        XCTAssertEqual(Set(TypLibrary.contents()), held, "and nothing was copied")
    }
}
