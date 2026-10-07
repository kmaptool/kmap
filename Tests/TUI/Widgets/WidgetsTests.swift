import XCTest

@testable import kmap

/// Moving through a list. Which row is selected and which rows are on screen are
/// separate questions; the selection must stay inside the window.
final class WidgetsTests: XCTestCase {
    func testMovingWrapsRoundTheEndsBecauseTheFarEndIsWhatYouAreReachingFor() {
        var list = ListState()
        list.move(-1, count: 10)
        XCTAssertEqual(list.selected, 9)
        list.move(1, count: 10)
        XCTAssertEqual(list.selected, 0)
        list.move(3, count: 10)
        XCTAssertEqual(list.selected, 3)
    }

    func testAPageJumpStopsAtTheEndRatherThanWrappingPastIt() {
        var list = ListState()
        list.jump(to: 2, count: 100)
        list.move(-20, count: 100, wrap: false)
        XCTAssertEqual(list.selected, 0)
        list.move(200, count: 100, wrap: false)
        XCTAssertEqual(list.selected, 99)
    }

    func testAnEmptyListSelectsNothingRatherThanRowMinusOne() {
        // A search with no hits, or a region with no children.
        var list = ListState()
        list.jump(to: 5, count: 10)
        list.move(0, count: 0)
        XCTAssertEqual(list.selected, 0)
        XCTAssertEqual(list.offset, 0)
        list.jump(to: 3, count: 0)
        XCTAssertEqual(list.selected, 0)
        list.clamp(count: 0, visible: 10)
        XCTAssertEqual(list.offset, 0)
    }

    func testJumpingIsHeldInsideTheList() {
        var list = ListState()
        list.jump(to: 999, count: 10)
        XCTAssertEqual(list.selected, 9)
        list.jump(to: -5, count: 10)
        XCTAssertEqual(list.selected, 0)
    }

    func testTheWindowFollowsTheSelectionDownAndBackUp() {
        var list = ListState()
        list.jump(to: 20, count: 100)
        list.clamp(count: 100, visible: 10)
        XCTAssertEqual(list.offset, 11)  // the selected row is the last shown
        XCTAssertTrue((list.offset..<(list.offset + 10)).contains(list.selected))
        list.jump(to: 5, count: 100)
        list.clamp(count: 100, visible: 10)
        XCTAssertEqual(list.offset, 5)
    }

    func testTheWindowNeverShowsPastTheEndOfTheList() {
        // Otherwise the last screenful is drawn half empty.
        var list = ListState()
        list.jump(to: 99, count: 100)
        list.clamp(count: 100, visible: 10)
        XCTAssertEqual(list.offset, 90)
        XCTAssertEqual(list.offset + 10, 100)
    }

    func testAListShorterThanTheWindowStartsAtTheTop() {
        var list = ListState()
        list.jump(to: 2, count: 3)
        list.clamp(count: 3, visible: 20)
        XCTAssertEqual(list.offset, 0)
    }

    func testAListThatShrankUnderTheSelectionIsPulledBackIn() {
        // Typing into the search box narrows the list while a far row is selected.
        var list = ListState()
        list.jump(to: 90, count: 100)
        list.clamp(count: 100, visible: 10)
        list.clamp(count: 4, visible: 10)
        XCTAssertEqual(list.selected, 3)
        XCTAssertEqual(list.offset, 0)
    }

    func testWalkingTheWholeListKeepsTheSelectionOnScreenAtEveryStep() {
        var list = ListState()
        for _ in 0..<250 {
            list.move(1, count: 200)
            list.clamp(count: 200, visible: 12)
            XCTAssertTrue(
                (list.offset..<(list.offset + 12)).contains(list.selected),
                "selected \(list.selected) outside \(list.offset)…"
            )
            XCTAssertLessThanOrEqual(list.offset + 12, 200)
        }
    }
}

/// The rectangles screens are laid out with.
final class RectTests: XCTestCase {
    func testInsettingPullsInFromEverySide() {
        let panel = Rect(x: 0, y: 0, w: 20, h: 10).inset(by: 2)
        XCTAssertEqual([panel.x, panel.y, panel.w, panel.h], [2, 2, 16, 6])
        let wide = Rect(x: 5, y: 5, w: 20, h: 10).inset(dx: 3, dy: 1)
        XCTAssertEqual([wide.x, wide.y, wide.w, wide.h], [8, 6, 14, 8])
    }

    func testInsettingPastTheMiddleGivesNothingRatherThanANegativeWidth() {
        // A narrow terminal: a box inset by more than it holds would draw backwards.
        let gone = Rect(x: 0, y: 0, w: 4, h: 2).inset(by: 3)
        XCTAssertEqual(gone.w, 0)
        XCTAssertEqual(gone.h, 0)
    }

    func testSplittingKeepsEveryColumnAndRowBetweenTheTwoHalves() {
        let (left, rest) = Rect(x: 0, y: 0, w: 30, h: 10).splitLeft(10)
        XCTAssertEqual(left.w + rest.w, 30)
        XCTAssertEqual(rest.x, left.maxX)
        let (top, below) = Rect(x: 0, y: 0, w: 30, h: 10).splitTop(3)
        XCTAssertEqual(top.h + below.h, 10)
        XCTAssertEqual(below.y, top.maxY)
    }

    func testSplittingOffMoreThanThereIsLeavesAnEmptyRemainder() {
        let (left, rest) = Rect(x: 0, y: 0, w: 8, h: 4).splitLeft(20)
        XCTAssertEqual(left.w, 8)
        XCTAssertEqual(rest.w, 0)
        let (top, below) = Rect(x: 0, y: 0, w: 8, h: 4).splitTop(-3)
        XCTAssertEqual(top.h, 0)
        XCTAssertEqual(below.h, 4)
    }
}

/// The log under a build: how far back it scrolls.
final class LogPaneTests: XCTestCase {
    /// One row of the surface as text, blanks either side dropped.
    private func row(_ y: Int, of surface: Surface) -> String {
        let text = String((0..<40).compactMap { surface.cell($0, y)?.ch })
        return text.trimmingCharacters(in: .whitespaces)
    }

    func testTheLogScrollsBackUntilItsFirstLineIsAtTheTopAndNoFurther() {
        XCTAssertEqual(Widgets.logScroll(500, lines: 100, height: 20), 80)
        XCTAssertEqual(Widgets.logScroll(30, lines: 100, height: 20), 30)
        XCTAssertEqual(Widgets.logScroll(-4, lines: 100, height: 20), 0)
        XCTAssertEqual(Widgets.logScroll(9, lines: 10, height: 20), 0, "a log shorter than its pane does not move")
    }

    /// Scrolled far past the start, the pane shows the first lines and stays full: it
    /// does not drain from the bottom one line a key.
    func testAPaneScrolledPastTheStartStaysFullFromTheFirstLine() {
        let lines = (1...30).map { LogEvent(text: "line \($0)") }
        let theme = Theme.strict
        let surface = Surface()
        surface.resize(40, 10)
        surface.clear(theme.base)
        Widgets.logPane(surface, rect: Rect(x: 0, y: 0, w: 40, h: 10), lines: lines, theme: theme, scrollOffset: 1000)
        XCTAssertEqual(row(0, of: surface), "line 1", "the first line at the top")
        XCTAssertEqual(row(9, of: surface), "line 10", "and the pane still full to the bottom")
    }
}
