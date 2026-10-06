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

    /// A header in other letters and a block closed by the next header read as mkgmap
    /// reads them: the point after the solid fill is not taken for part of it.
    func testAHatchIsFoundAsMkgmapReadsTheBlocks() {
        let text = """
            [_Polygon]
            Type=0x50
            Xpm="2 2 2 1"
            "! c none"
            "  c #008000"
            [_polygon]
            Type=0x01
            Xpm="2 2 1 1"
            "  c #FF0000"
            [_point]
            Type=0x2f00
            DayXpm="1 1 2 1"
            "a c none"
            "b c #000000"
            "a"
            [end]
            """
        XCTAssertEqual(BuildPipeline.hatchedPolygonTypes(inSource: text), ["0x50"])
    }
}
