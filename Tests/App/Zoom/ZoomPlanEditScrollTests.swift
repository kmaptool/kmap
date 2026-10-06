import XCTest

@testable import kmap

/// On a terminal too short for every family the grid scrolls with the cursor: a row the
/// cursor is on is drawn, so space never edits a row out of sight.
@MainActor
final class ZoomPlanEditScrollTests: XCTestCase {
    func testTheCursorsFamilyIsAlwaysDrawn() {
        let ctx = AppContext()
        let screen = ZoomPlanEditScreen(plan: ZoomPlan.builtins[0], settings: ctx.settings)
        func drawn() -> String {
            let surface = Surface()
            surface.resize(80, 24)
            surface.clear(ctx.theme.base)
            screen.render(into: surface, rect: Rect(x: 0, y: 2, w: 80, h: 20), ctx: ctx)
            return stripControlSequences(surface.compose())
        }
        let count = screen.rows.count
        XCTAssertGreaterThan(count, 15, "more families than an 80x24 terminal shows")
        for at in 1..<count {
            screen.list.selected = at
            guard case .family(let family) = screen.rows[at] else { continue }
            XCTAssertTrue(drawn().contains(family.name), "\(family.name) at row \(at)")
        }
        screen.list.selected = 1
        guard case .family(let first) = screen.rows[1] else { return XCTFail() }
        XCTAssertTrue(drawn().contains(first.name), "back at the top")
    }
}
