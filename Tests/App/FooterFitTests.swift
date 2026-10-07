import XCTest

@testable import kmap

/// A footer too narrow for every hint keeps the last ones, saving and leaving, and says
/// that some were left out.
@MainActor
final class FooterFitTests: XCTestCase {
    func testTheLastHintsStayAndAnEllipsisMarksTheGap() async throws {
        let hints =
            (1...8).map { Hint(key: "k\($0)", label: "label \($0)") } + [
                Hint(key: "^S", label: "save"), Hint(key: "esc", label: "back")
            ]
        XCTAssertNil(App.fitting(hints, into: 60))
        let kept = try XCTUnwrap(App.fitting(hints, into: 60, dropping: true))
        XCTAssertEqual(kept.suffix(2).map(\.key), ["^S", "esc"])
        XCTAssertTrue(kept.contains { $0.key.isEmpty && $0.label == "…" })
        XCTAssertEqual(kept.first?.key, "k1")
        XCTAssertEqual(App.fitting(hints, into: 500)?.count, hints.count)
    }

    /// The way on and the way back stay wherever a screen lists them.
    func testEnterAndEscStayWhereverTheyStand() async throws {
        let hints =
            [Hint(key: Glyph.enter, label: "done"), Hint(key: "esc", label: "back")]
            + (1...8).map { Hint(key: "k\($0)", label: "label \($0)") }
        let kept = try XCTUnwrap(App.fitting(hints, into: 60, dropping: true))
        XCTAssertEqual(kept.prefix(2).map(\.key), [Glyph.enter, "esc"])
        XCTAssertEqual(kept.suffix(2).map(\.key), ["k7", "k8"])
        XCTAssertTrue(kept.contains { $0.key.isEmpty && $0.label == "…" })
    }

    /// Where the last 2 do not fit beside Enter and Esc, those go too.
    func testTheLastHintsWinWhenEnterAndEscLeaveNoRoom() async throws {
        let hints = [
            Hint(key: Glyph.enter, label: "done"), Hint(key: "esc", label: "back to the map's settings"),
            Hint(key: "↑↓", label: "scroll log"), Hint(key: "v", label: "detail")
        ]
        let kept = try XCTUnwrap(App.fitting(hints, into: 40, dropping: true))
        XCTAssertEqual(kept.suffix(2).map(\.key), ["↑↓", "v"])
        XCTAssertFalse(kept.contains { $0.key == "esc" })
        XCTAssertTrue(kept.contains { $0.key.isEmpty && $0.label == "…" })
    }
}
