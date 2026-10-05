import XCTest

@testable import kmap

final class HatchedPolygonTests: XCTestCase {
    private let source = """
        [_polygon]
        Type=0x4b
        Xpm="2 2 1 1"
        "  c #00FF00"
        [end]
        [_polygon]
          Type=0x50
        Xpm="2 2 2 1"
        "! c none"
        "  c #008000"
        [end]
        """

    func testAHatchIsFoundWithEveryLineEnding() {
        XCTAssertEqual(BuildPipeline.hatchedPolygonTypes(inSource: source), ["0x50"])
        let crlf = source.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(BuildPipeline.hatchedPolygonTypes(inSource: crlf), ["0x50"])
    }
}
