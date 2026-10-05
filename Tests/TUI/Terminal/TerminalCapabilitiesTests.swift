import XCTest

@testable import kmap

final class TerminalCapabilitiesTests: XCTestCase {
    func testTrueColourIsLeftOutWhereTheTerminalWouldShowItWrong() {
        func asks(_ environment: [String: String], macOS: Int = 15) -> Bool {
            TerminalCapabilities.trueColour(environment: environment, macOSMajor: macOS)
        }
        XCTAssertTrue(asks(["TERM": "xterm-256color"]))
        XCTAssertFalse(asks(["TERM": "linux"]))
        XCTAssertFalse(asks(["TERM": "screen.xterm-256color"]))
        XCTAssertTrue(asks(["TERM": "screen", "COLORTERM": "truecolor"]))
        XCTAssertFalse(asks(["TERM": "xterm-256color", "KMAP_TRUECOLOR": "0"]))
        XCTAssertTrue(asks(["TERM": "linux", "KMAP_TRUECOLOR": "1"]))
        #if os(macOS)
        XCTAssertFalse(asks(["TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"], macOS: 15))
        XCTAssertTrue(asks(["TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"], macOS: 26))
        #endif
    }
}
