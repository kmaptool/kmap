import XCTest
@testable import kmap

/// The TYP of a ported look: their drawings on kmap's numbers, and the ground kmap lays
/// under a style that paints none.
final class StylePortTypTests: XCTestCase {

    private func ported(_ kind: MapElementKind, ours: Int, theirs: Int) -> StylePort.Ported {
        StylePort.Ported(ours: ours, theirs: theirs, kind: kind, meaning: "test",
                         witnesses: 10, width: nil)
    }

    private func typ(_ source: String, ported: [StylePort.Ported] = [],
                     familyID: Int? = nil, productID: Int? = nil, codePage: Int? = nil) -> [String] {
        StylePort.typ(from: TypSource.parse(source), ported: ported, familyID: familyID,
                      productID: productID, codePage: codePage)
            .components(separatedBy: "\n")
    }

    // MARK: Brightness and the two questions asked of a style

    func testBrightnessRunsFromBlackToWhite() {
        XCTAssertEqual(StylePort.brightness(of: "#000000"), 0, accuracy: 1e-9)
        XCTAssertEqual(StylePort.brightness(of: "#FFFFFF"), 1, accuracy: 1e-9)
        XCTAssertEqual(StylePort.brightness(of: "ffffff"), 1, accuracy: 1e-9, "the # is optional")
        XCTAssertLessThan(StylePort.brightness(of: "#0000FF"), StylePort.brightness(of: "#00FF00"),
                          "green reads brighter than blue")
    }

    func testAnUnreadableColourCountsAsLight() {
        // So that a style is never called dark on the strength of what could not be read.
        for nonsense in ["", "#12", "#GGGGGG", "transparent"] {
            XCTAssertEqual(StylePort.brightness(of: nonsense), 1, nonsense)
        }
    }

    func testAStyleThatPaintsNothingIsNeitherNightNorDark() {
        let empty = TypSource.parse("[_id]\nFID=1\n[end]\n")
        XCTAssertFalse(StylePort.paintsNight(empty))
        XCTAssertFalse(StylePort.drawsDark(empty))
    }

    // MARK: The header

    func testTheHeaderCarriesTheIdentityItIsGiven() {
        let lines = typ("", familyID: 6313, productID: 1, codePage: 1251)
        XCTAssertEqual(lines.first, "; -*- coding: UTF-8 -*-", "first, or Cyrillic labels are misread")
        XCTAssertTrue(lines.contains("; " + StylePort.forOurNumbers))
        XCTAssertTrue(lines.contains("FID=6313"))
        XCTAssertTrue(lines.contains("ProductCode=1"))
        XCTAssertTrue(lines.contains("CodePage=1251"))
    }

    func testAnIdentityNotGivenIsNotInvented() {
        let lines = typ("")
        XCTAssertFalse(lines.contains { $0.hasPrefix("FID=") || $0.hasPrefix("CodePage=") })
    }

    // MARK: Renumbering

    private let theirPoint = """
        [_point]
        Type=0x2f
        SubType=0x07
        String=0x04,Spring
        [end]
        """

    func testAPointTakesOurTypeAndSubtype() {
        let lines = typ(theirPoint, ported: [ported(.point, ours: 0x6511, theirs: 0x2f07)])
        let at = try? XCTUnwrap(lines.firstIndex(of: "Type=0x65"))
        XCTAssertNotNil(at)
        XCTAssertTrue(lines.contains("SubType=0x11"))
        XCTAssertTrue(lines.contains("String=0x04,Spring"), "the rest of their block is verbatim")
        XCTAssertFalse(lines.contains("Type=0x2f"))
    }

    func testAPointBlockThatNeverSaidSubTypeGetsOne() {
        // Some files fold the subtype into the type, `Type=0x2f07`, and have no SubType
        // line to rewrite.
        let bare = """
            [_point]
            Type=0x2f07
            String=0x04,Spring
            [end]
            """
        let lines = typ(bare, ported: [ported(.point, ours: 0x6511, theirs: 0x2f07)])
        let type = try? XCTUnwrap(lines.firstIndex(of: "Type=0x65"))
        XCTAssertEqual(type.map { lines[$0 + 1] }, "SubType=0x11", "right under the type")
    }

    // MARK: The ground

    func testAStyleWithoutGroundGetsKmapsOwn() {
        // A polygon missing from the draw order is not drawn, and undrawn land goes black
        // on a fenix: so the paper and the sea are supplied.
        let text = typ(theirPoint).joined(separator: "\n")
        XCTAssertTrue(text.contains(String(format: "Type=0x%02x", StylePort.backgroundCode)))
        XCTAssertTrue(text.contains(String(format: "Type=0x%02x", StylePort.seaCode)))
        XCTAssertTrue(text.contains(StylePort.paper))
        XCTAssertTrue(text.contains(StylePort.seaBlue))
        XCTAssertFalse(text.contains(StylePort.paperAtNight), "a day-only style gets a day-only ground")
    }

    func testTheirOwnGroundIsKeptWhereTheyPaintOne() {
        let ground = """
            [_polygon]
            Type=0x4b
            Xpm="0 0 1 0"
            "1 c #123456"
            [end]
            """
        let text = typ(ground).joined(separator: "\n")
        XCTAssertTrue(text.contains("#123456"))
        XCTAssertFalse(text.contains(StylePort.paper), "their paper, not ours")
    }
}
