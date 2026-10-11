import XCTest

@testable import kmap

/// The road wears nothing and its twin wears the road's look, so 1 line is seen.
final class TypAugmentRoadTwinsTests: XCTestCase {
    private let typ = """
        [_id]
        FID=1
        ProductCode=1
        [end]

        [_line]
        Type=0x16
        UseOrientation=Y
        Xpm="32 1 2 1"
        "! c #303030"
        ". c none"
        "!!!..!!!..!!!..!!!..!!!..!!!..!!"
        String=0x00,Path
        String=0x19,Тропа
        FontStyle=SmallFont
        [end]

        [_line]
        Type = 0x27
        Xpm="0 0 1 0"
        "1 c #ff0000"
        LineWidth=2
        String1=0x00,Gravel
        [end]

        [_line]
        Type=0x18
        Xpm="0 0 1 0"
        "1 c #0000ff"
        LineWidth=1
        [end]
        """

    private func file(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("twin-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheRoadIsDrawnAsNothingAndItsTwinAsTheRoadWas() throws {
        let url = try file(typ)
        XCTAssertEqual(TypAugment.twinRoads(in: url, roads: [0x16, 0x0a], taken: [0x16, 0x0a, 0x18]), [0x16: 0x11f16])
        let source = TypSource.parse(try String(contentsOf: url, encoding: .utf8))
        let road = try XCTUnwrap(source.section(.line, 0x16))
        XCTAssertEqual(road.picture?.dominantColour, nil, "the road is transparent")
        XCTAssertEqual(road.fontStyle, "NoLabel")
        XCTAssertEqual(road.labels.map(\.text), ["Path", "Тропа"], "its names stay for the receiver's lists")
        let twin = try XCTUnwrap(source.section(.line, 0x11f16))
        XCTAssertEqual(twin.picture?.dominantColour?.uppercased(), "#303030")
        XCTAssertEqual(twin.fontStyle, "SmallFont")
        XCTAssertEqual(twin.labels.map(\.text), ["Path", "Тропа"])
        XCTAssertNotNil(source.section(.line, 0x18), "a plain line is left alone")
    }

    /// A block the TYP or the rules already use is passed over for the next free one.
    func testATakenBlockIsPassedOver() throws {
        let url = try file(typ)
        XCTAssertEqual(TypAugment.twinRoads(in: url, roads: [0x16], taken: [0x11f16]), [0x16: 0x11e16])
    }

    /// An extended number holds a low byte up to 0x1f, so a road above it keeps its look.
    func testARoadAbove0x1fIsNotTwinned() throws {
        let url = try file(typ)
        XCTAssertEqual(TypAugment.twinRoads(in: url, roads: [0x27], taken: []), [:])
    }

    /// `Type = ` with spaces is renumbered in the copy, and any kind of label line stays.
    func testSpacedKeysAndNumberedLabelsAreRead() throws {
        let url = try file(
            typ.replacingOccurrences(of: "Type=0x16", with: "Type = 0x16")
                .replacingOccurrences(of: "String=0x00,Path", with: "String1=0x00,Path")
        )
        XCTAssertEqual(TypAugment.twinRoads(in: url, roads: [0x16], taken: []), [0x16: 0x11f16])
        let text = try String(contentsOf: url, encoding: .utf8)
        let source = TypSource.parse(text)
        XCTAssertEqual(source.sections.filter { $0.code == 0x16 }.count, 1)
        XCTAssertNotNil(source.section(.line, 0x11f16))
        XCTAssertEqual(text.components(separatedBy: "String1=0x00,Path").count, 3, "on the road and its twin")
    }

    /// A road the TYP leaves to the receiver has no look to move.
    func testARoadTheTypDoesNotDrawIsNotTwinnedHere() throws {
        let url = try file(typ)
        XCTAssertEqual(TypAugment.twinRoads(in: url, roads: [0x06], taken: []), [:])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), typ, "nothing written")
    }
}
