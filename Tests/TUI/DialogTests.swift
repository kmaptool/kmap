import XCTest
@testable import kmap

/// The modal question and the friction it carries: the confirming answer is never the
/// one under the cursor when the dialog opens.
final class DialogTests: XCTestCase {

    private func rights() -> Dialog {
        Dialog(title: "Important",
               body: ["I confirm that the copyright is mine.",
                      "The copy stays on this machine."],
               detail: [("file", "style.typ"), ("from", "/Volumes/Disk/Garmin")],
               confirm: "I confirm", cancel: "cancel")
    }

    private func surface(_ w: Int = 100, _ h: Int = 30) -> Surface {
        let s = Surface()
        s.resize(w, h)
        s.clear(Style(fg: .xterm(252), bg: .xterm(233)))
        return s
    }

    // MARK: Answering it

    func testItOpensOnTheAnswerThatChangesNothing() {
        XCTAssertEqual(rights().focus, .cancel)
    }

    func testEnterOnItsOwnCancels() {
        var dialog = rights()
        XCTAssertEqual(dialog.handle(.enter), .cancelled)
    }

    func testAgreeingTakesAMoveAndThenAPress() {
        var dialog = rights()
        XCTAssertEqual(dialog.handle(.right), .none)
        XCTAssertEqual(dialog.focus, .confirm)
        XCTAssertEqual(dialog.handle(.enter), .confirmed)
    }

    func testEscapeCancelsFromEitherSide() {
        var onCancel = rights()
        XCTAssertEqual(onCancel.handle(.esc), .cancelled)

        var onConfirm = rights()
        _ = onConfirm.handle(.right)
        XCTAssertEqual(onConfirm.handle(.esc), .cancelled)
    }

    func testTheArrowsAndTabAllMoveBetweenTheTwo() {
        var dialog = rights()
        for key in [KeyEvent.right, .left, .tab, .backTab] {
            let was = dialog.focus
            XCTAssertEqual(dialog.handle(key), .none)
            XCTAssertNotEqual(dialog.focus, was, "\(key) should move the cursor")
        }
    }

    func testKeysItDoesNotKnowDoNothingRatherThanFallingThrough() {
        // While it is up it is the screen: keys do not reach the list underneath.
        var dialog = rights()
        XCTAssertEqual(dialog.handle(.char("y")), .none)
        XCTAssertEqual(dialog.handle(.down), .none)
        XCTAssertEqual(dialog.focus, .cancel)
    }

    func testTheFooterSaysWhatEnterWillDo() {
        var dialog = rights()
        XCTAssertEqual(dialog.footerHints.first { $0.key == "⏎" }?.label, "cancel")
        _ = dialog.handle(.right)
        XCTAssertEqual(dialog.footerHints.first { $0.key == "⏎" }?.label, "I confirm")
    }

    // MARK: Drawing it

    func testItIsRedWithWhiteLettersAndNotTheAppsOwnGreys() {
        // The theme's near-monochrome would read as an ordinary panel.
        let s = surface()
        let dialog = rights()
        let area = Rect(x: 0, y: 0, w: 100, h: 30)
        dialog.render(into: s, rect: area, theme: .strict)

        let middle = s.cell(50, 15 - dialog.height(in: area) / 2 + 3)
        guard case .rgb(let r, let g, let b)? = middle?.style.bg.kind else {
            return XCTFail("the box is not filled with a colour of its own")
        }
        XCTAssertGreaterThan(Int(r), 90, "red")
        XCTAssertLessThan(Int(g) + Int(b), 80, "and not much else")
        XCTAssertEqual(s.cell(50, 15)?.style.fg, Color.rgb(255, 255, 255))
    }

    func testItSaysWhatIsBeingAgreedAbout() {
        let s = surface()
        rights().render(into: s, rect: Rect(x: 0, y: 0, w: 100, h: 30), theme: .strict)
        let drawn = s.compose()
        XCTAssertTrue(drawn.contains("IMPORTANT"))
        XCTAssertTrue(drawn.contains("style.typ"))
        XCTAssertTrue(drawn.contains("/Volumes/Disk/Garmin"))
        XCTAssertTrue(drawn.contains("I confirm"))
        XCTAssertTrue(drawn.contains("cancel"))
    }

    func testBothButtonsAreInsideTheBox() {
        // The height is counted from the contents rather than estimated.
        let area = Rect(x: 0, y: 0, w: 100, h: 30)
        let s = surface()
        let dialog = rights()
        dialog.render(into: s, rect: area, theme: .strict)

        let top = (30 - dialog.height(in: area)) / 2
        let bottom = top + dialog.height(in: area) - 1
        var buttonRow: Int?
        for y in top...bottom where rowText(s, y).contains("I confirm") { buttonRow = y }
        let row = try? XCTUnwrap(buttonRow)
        XCTAssertNotNil(row)
        if let row { XCTAssertLessThan(row, bottom, "the buttons are outside the border") }
        XCTAssertTrue(rowText(s, bottom).contains("└"), "the box has to close under them")
    }

    func testItFitsANarrowWindowRatherThanDrawingOffTheEdge() {
        for width in [40, 60, 100, 200] {
            let s = surface(width, 30)
            let area = Rect(x: 0, y: 0, w: width, h: 30)
            rights().render(into: s, rect: area, theme: .strict)
            for y in 0..<30 {
                XCTAssertEqual(s.cell(width - 1, y)?.style.bg, Color.xterm(233),
                               "the box reached the edge of a \(width) column window")
            }
        }
    }

    /// A dialog too short for its text marks the clipping rather than dropping it silently.
    func testAClippedDialogSaysThatItWasClipped() {
        let wordy = Dialog(
            title: "Important",
            body: (1...6).map { "Paragraph \($0), long enough to wrap across the box more"
                              + " than once and push what follows below the fold." },
            detail: [("file", "style.typ")],
            confirm: "I confirm", cancel: "cancel")
        let s = surface(80, 12)
        wordy.render(into: s, rect: Rect(x: 0, y: 0, w: 80, h: 12), theme: .strict)
        let shown = (0..<12).map { rowText(s, $0) }.joined(separator: "\n")
        XCTAssertTrue(shown.contains("…"), "clipped text must leave a mark")
        // A window with room carries no such mark.
        let roomy = surface(80, 40)
        wordy.render(into: roomy, rect: Rect(x: 0, y: 0, w: 80, h: 40), theme: .strict)
        let all = (0..<40).map { rowText(roomy, $0) }.joined(separator: "\n")
        XCTAssertFalse(all.contains("…"))
        XCTAssertTrue(all.contains("Paragraph 6"))
    }

    private func rowText(_ s: Surface, _ y: Int) -> String {
        (0..<s.width).map { String(s.cell($0, y)?.ch ?? " ") }.joined()
    }
}
