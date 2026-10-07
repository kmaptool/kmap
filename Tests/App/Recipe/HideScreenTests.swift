import XCTest

@testable import kmap

/// Typing filters, spaces included; only Enter, or space with nothing typed, toggles.
@MainActor
final class HideScreenTests: XCTestCase {
    func testASpaceInTheFilterHidesNothing() async {
        let ctx = AppContext()
        var hidden: Set<String> = []
        let screen = HideScreen(hidden: []) { hidden = $0 }
        for character in "bus stop" { _ = screen.handle(.char(character), ctx: ctx) }
        XCTAssertTrue(hidden.isEmpty)
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertEqual(hidden.count, 1, "Enter toggles what the filter shows")
    }
}
