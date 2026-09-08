import XCTest
@testable import kmap

/// An open dropdown is drawn in the overlay pass, after the summary panel beside the form,
/// and is clamped to the form's column: in the finished screen it is still a rectangle
/// nothing is painted through.
final class PickerOverlayTests: XCTestCase {

    private var ctx: AppContext!

    private static let somewhere = Region(
        id: "large-region", name: "Large Inland Region",
        parentID: nil, pbfURL: nil,
        bbox: BBox(minLon: 32.15, minLat: 43.18, maxLon: 36.68, maxLat: 46.25),
        boxes: [], childIDs: [])

    @MainActor
    override func setUp() async throws {
        ctx = AppContext()
    }

    /// The box as it ended up on screen: the row of its top border, and the columns its
    /// two sides sit in.
    private func boxOnScreen(_ rows: [String]) -> (top: Int, bottom: Int, left: Int, right: Int)? {
        guard let top = rows.firstIndex(where: { $0.contains(Glyph.tl) }) else { return nil }
        let line = Array(rows[top])
        guard let left = line.firstIndex(of: Glyph.tl),
              let right = line.firstIndex(of: Glyph.tr),
              let bottom = rows.indices.dropFirst(top).first(where: { rows[$0].contains(Glyph.bl) })
        else { return nil }
        return (top, bottom, left, right)
    }

    @MainActor
    private func screenWithAnOpenPicker(width: Int, height: Int) -> [String] {
        let screen = RecipeScreen(region: Self.somewhere, settings: ctx.settings,
                                  hasSeamPatch: true)
        let surface = Surface()
        surface.resize(width, height)
        surface.clear(ctx.theme.base)
        screen.tick(ctx)

        // The longest list on the form: the description carriers run to forty-odd
        // characters.
        let rect = Rect(x: 2, y: 2, w: width - 4, h: height - 4)
        screen.render(into: surface, rect: rect, ctx: ctx)
        screen.openPicker(.descriptions, ctx)
        surface.clear(ctx.theme.base)
        screen.render(into: surface, rect: rect, ctx: ctx)
        screen.renderOverlay(into: surface, rect: rect, ctx: ctx)
        return surface.asText().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @MainActor
    func testTheBoxIsStillARectangleAfterEverythingElseIsDrawn() async throws {
        for (width, height) in [(110, 40), (130, 44)] {
            let rows = screenWithAnOpenPicker(width: width, height: height)
            guard let box = boxOnScreen(rows) else {
                XCTFail("no dropdown was drawn at \(width)x\(height)"); continue
            }
            for y in (box.top + 1)..<box.bottom {
                let line = Array(rows[y])
                XCTAssertEqual(line[safe: box.left], Glyph.v,
                               "left side missing at row \(y), \(width)x\(height)")
                XCTAssertEqual(line[safe: box.right], Glyph.v,
                               "right side painted over at row \(y), \(width)x\(height)")
                let inside = line[(box.left + 1)..<box.right]
                XCTAssertFalse(inside.contains(Glyph.v),
                               "something was drawn through the box at row \(y): "
                               + String(inside))
            }
        }
    }

    @MainActor
    func testTheBoxStaysInsideTheFormColumn() async throws {
        let width = 130
        let rows = screenWithAnOpenPicker(width: width, height: 44)
        let box = try XCTUnwrap(boxOnScreen(rows))
        let form = Layout.split(Rect(x: 2, y: 2, w: width - 4, h: 40)).form
        XCTAssertGreaterThanOrEqual(box.left, form.x)
        XCTAssertLessThan(box.right, form.maxX)
    }
}
