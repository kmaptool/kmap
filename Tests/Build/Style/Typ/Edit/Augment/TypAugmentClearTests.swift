import XCTest

@testable import kmap

/// A line no rule could be silenced for is painted clear, so the receiver does not
/// draw it its own way.
final class TypAugmentClearTests: XCTestCase {
    private let typ = """
        [_id]
        FID=1
        ProductCode=1
        [end]

        [_polygon]
        Type=0x50
        Xpm="0 0 1 0"
        "! c #60B020"
        [end]

        [_line]
        Type=0x18
        Xpm="0 0 1 0"
        "1 c #0000ff"
        LineWidth=1
        [end]
        """

    private func typCopy() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clear-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try typ.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAnUnpaintedLineGetsASectionThatDrawsNothing() throws {
        let url = try typCopy()
        XCTAssertEqual(TypAugment.paintClear(lines: [0x30, 0x10f1d], in: url), 2)
        let source = try XCTUnwrap(TypSource.read(url))
        for code in [0x30, 0x10f1d] {
            let section: TypSection = try XCTUnwrap(source.section(.line, code), "\(code)")
            XCTAssertFalse(StylePort.draws(section), "\(code) draws")
        }
        // What the style paints stays as it was, and no area is touched.
        XCTAssertTrue(StylePort.draws(source.section(.line, 0x18)))
        XCTAssertEqual(source.sections.filter { $0.kind == .polygon }.map(\.code), [0x50])
        // A second pass finds its own sections.
        XCTAssertEqual(TypAugment.paintClear(lines: [0x30, 0x10f1d], in: url), 0)
    }

    func testANumberTheStylePaintsIsLeftAlone() throws {
        let url = try typCopy()
        XCTAssertEqual(TypAugment.paintClear(lines: [0x18], in: url), 0)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), typ)
    }

    func testACopyThatCannotBeReadSaysSo() {
        XCTAssertNil(TypAugment.paintClear(lines: [0x30], in: URL(fileURLWithPath: "/nonexistent/copy.txt")))
    }
}
