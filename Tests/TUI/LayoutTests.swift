import XCTest
@testable import kmap

/// Where a screen's columns fall: the split between the form and the side panel, and
/// the width at which the panel is dropped.
final class LayoutTests: XCTestCase {

    func testAWideScreenGetsBothTheFormAndThePanel() {
        let (form, panel) = Layout.split(Rect(x: 2, y: 1, w: 116, h: 40))
        XCTAssertEqual(form.w, Layout.formWidth, "a form stops being useful past its width")
        XCTAssertEqual(form.x, 2)
        XCTAssertNotNil(panel)
        XCTAssertEqual(panel!.x, 2 + Layout.formWidth + Layout.gutter)
        XCTAssertEqual(panel!.maxX, 118, "the panel runs to the edge")
        XCTAssertEqual(panel!.h, 40)
    }

    /// Below the threshold the panel is dropped rather than squeezed.
    func testANarrowScreenGetsTheFormAlone() {
        let (form, panel) = Layout.split(Rect(x: 0, y: 0, w: Layout.panelNeeds - 1, h: 20))
        XCTAssertNil(panel)
        XCTAssertEqual(form.w, Layout.formWidth)
    }

    /// At the threshold the panel appears at full width; the form gives up the columns.
    func testAtTheThresholdThePanelStillHasItsWidth() {
        let (form, panel) = Layout.split(Rect(x: 0, y: 0, w: Layout.panelNeeds, h: 20))
        XCTAssertNotNil(panel)
        XCTAssertGreaterThanOrEqual(panel!.w, Layout.panelWidth - Layout.gutter)
        XCTAssertEqual(form.w, Layout.panelNeeds - Layout.panelWidth)
    }

    func testAScreenNarrowerThanTheFormIsNotWidenedToFitIt() {
        let (form, panel) = Layout.split(Rect(x: 0, y: 0, w: 30, h: 10))
        XCTAssertNil(panel)
        XCTAssertEqual(form.w, 30, "a form cannot be wider than the screen it is on")
    }
}
