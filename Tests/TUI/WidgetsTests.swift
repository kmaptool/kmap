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
        XCTAssertEqual(list.offset, 11)                 // the selected row is the last shown
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
            XCTAssertTrue((list.offset..<(list.offset + 12)).contains(list.selected),
                          "selected \(list.selected) outside \(list.offset)…")
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
