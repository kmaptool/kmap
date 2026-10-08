import XCTest

@testable import kmap

/// Esc steps back through the screens; on the main menu it must not close kmap, or one
/// press too many on the way back ends the session.
@MainActor
final class MainMenuKeysTests: XCTestCase {
    func testEscOnTheMainMenuDoesNotCloseKmap() async {
        let ctx = AppContext()
        let menu = MainMenuScreen()
        if case .none = menu.handle(.esc, ctx: ctx) {} else { XCTFail("Esc on the main menu") }
        if case .quit = menu.handle(.char("q"), ctx: ctx) {} else { XCTFail("q leaves") }
        if case .quit = menu.handle(.ctrl("c"), ctx: ctx) {} else { XCTFail("^C leaves") }
    }
}
