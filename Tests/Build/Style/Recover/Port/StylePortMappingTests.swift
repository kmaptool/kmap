import XCTest

@testable import kmap

/// A porting's context and the steps that pair their pictures with our numbers.
final class StylePortMappingTests: XCTestCase {
    private func rules(_ polygons: String) throws -> RuleSetIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mapping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try polygons.write(to: dir.appendingPathComponent("polygons"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(RuleSetIndex.read(styleDirectory: dir))
    }

    /// A picture their number draws only a sliver of as this meaning is a stray: a reserve
    /// lies on forest, and their forest is no reserve.
    func testAPictureSeenOnASliverOfItsDrawingIsAStray() throws {
        let mapping = StylePort.Mapping(
            codesByTag: ["leisure=nature_reserve": ["A52": 3], "natural=wood": ["A52": 1000]],
            rules: try rules("leisure=nature_reserve [0x16 resolution 18]\n"),
            theirZooms: [:],
            theirTyp: nil,
            theirAreas: [:]
        )
        XCTAssertEqual(mapping.seen["A52"], 1003)
        XCTAssertTrue(mapping.isStray(0x52, .polygon, 3))
        XCTAssertFalse(mapping.isStray(0x52, .polygon, 1000))
    }

    /// 2 meanings on 1 number of ours: each offers its picture, and the one the evidence
    /// holds best wins.
    func testANumberTakesThePictureTheEvidenceHoldsBest() throws {
        let mapping = StylePort.Mapping(
            codesByTag: ["landuse=forest": ["A50": 40], "natural=wood": ["A51": 10]],
            rules: try rules("landuse=forest [0x50 resolution 19]\nnatural=wood [0x50 resolution 19]\n"),
            theirZooms: [:],
            theirTyp: nil,
            theirAreas: [:]
        )
        XCTAssertEqual(mapping.offers()[.polygon]?[0x50]?.keys.sorted(), [0x50, 0x51])
        XCTAssertEqual(mapping.ported().map(\.theirs), [0x50])
    }
}
