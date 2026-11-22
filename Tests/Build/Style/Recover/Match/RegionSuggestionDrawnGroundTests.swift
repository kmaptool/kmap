import XCTest

@testable import kmap

/// Where a map draws is where its finest subdivisions hold bytes, not the rectangles of
/// its tiles.
final class RegionSuggestionDrawnGroundTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-drawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func map(_ files: [(String, String, [UInt8])]) throws -> URL {
        try ImgFixture.container(files, into: directory)
    }

    private func assertBox(
        _ box: BBox,
        _ expected: [Double],
        accuracy: Double = 1e-4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (got, want) in zip([box.minLon, box.minLat, box.maxLon, box.maxLat], expected) {
            XCTAssertEqual(got, want, accuracy: accuracy, "\(box)", file: file, line: line)
        }
    }

    func testEverySubdivisionWithDataIsASpotWeighedByItsBytes() throws {
        let tile = BBox(minLon: 1, minLat: 42, maxLon: 8, maxLat: 44)
        let img = try map([
            (
                "63000001", "TRE",
                TreFixture.tre(
                    bounds: tile,
                    detail: [
                        .init(lon: 1.5, lat: 42.5, halfLon: 0.1, halfLat: 0.05, bytes: 900),
                        .init(lon: 5, lat: 43, halfLon: 0.2, halfLat: 0.2, bytes: 0),
                        .init(lon: 7.4, lat: 43.7, halfLon: 0.05, halfLat: 0.05, bytes: 100)
                    ]
                )
            ),
            ("63000001", "RGN", [UInt8](repeating: 0, count: 5000))
        ])
        let drawn = RegionSuggestion.drawnGround(of: img)
        assertBox(RegionSuggestion.frame(of: img), [1, 42, 8, 44])
        XCTAssertEqual(drawn.tiles.count, 1)
        XCTAssertEqual(
            drawn.spots.map(\.weight),
            [900, 100],
            "the empty subdivision and the coarse level weigh nothing"
        )
        assertBox(drawn.spots[0].box, [1.4, 42.45, 1.6, 42.55])
        assertBox(drawn.spots[1].box, [7.35, 43.65, 7.45, 43.75])
    }

    func testASubdivisionIsCutToItsTile() throws {
        let img = try map([
            (
                "63000001", "TRE",
                TreFixture.tre(
                    bounds: BBox(minLon: 10, minLat: 50, maxLon: 11, maxLat: 51),
                    detail: [.init(lon: 10.95, lat: 50.5, halfLon: 0.1, halfLat: 0.1, bytes: 10)]
                )
            )
        ])
        assertBox(RegionSuggestion.drawnGround(of: img).spots[0].box, [10.85, 50.4, 11, 50.6])
    }

    /// No subdivision reads: the tile is 1 spot, by the size of its RGN.
    func testATileWithoutSubdivisionsIsWeighedWhole() throws {
        let tile = BBox(minLon: 10, minLat: 50, maxLon: 11, maxLat: 51)
        let img = try map([
            ("63000001", "TRE", TreFixture.tre(bounds: tile, detail: [])),
            ("63000001", "RGN", [UInt8](repeating: 0, count: 700))
        ])
        let drawn = RegionSuggestion.drawnGround(of: img)
        XCTAssertEqual(drawn.spots.map(\.weight), [700])
        assertBox(drawn.spots[0].box, [10, 50, 11, 51])
    }

    /// Nothing to weigh by at all: by area, and never all zeros.
    func testAMapWithNoSizesIsWeighedByArea() throws {
        let tile = BBox(minLon: 10, minLat: 50, maxLon: 12, maxLat: 51)
        let img = try map([("63000001", "TRE", TreFixture.tre(bounds: tile, detail: []))])
        let spots = RegionSuggestion.drawnGround(of: img).spots
        XCTAssertEqual(spots.count, 1)
        XCTAssertEqual(spots[0].weight, 2, accuracy: 1e-4, "2 square degrees")
    }

    /// A tile across 180 deg: its subdivisions lie either side, and so do the spots.
    func testATileAcrossTheAntimeridianKeepsBothSides() throws {
        let img = try map([
            (
                "63000001", "TRE",
                TreFixture.tre(
                    bounds: BBox(minLon: 178, minLat: 60, maxLon: 182, maxLat: 62),
                    detail: [
                        .init(lon: 179, lat: 61, halfLon: 0.1, halfLat: 0.1, bytes: 30),
                        .init(lon: 181, lat: 61, halfLon: 0.1, halfLat: 0.1, bytes: 70),
                        .init(lon: 180, lat: 61, halfLon: 0.1, halfLat: 0.1, bytes: 40)
                    ]
                )
            )
        ])
        let drawn = RegionSuggestion.drawnGround(of: img)
        assertBox(RegionSuggestion.frame(of: img), [178, 60, 182, 62])
        XCTAssertEqual(drawn.tiles.count, 2)
        assertBox(drawn.tiles[0], [178, 60, 180, 62])
        assertBox(drawn.tiles[1], [-180, 60, -178, 62])
        XCTAssertEqual(drawn.spots.count, 4, "the one on the line is its 2 halves")
        assertBox(drawn.spots[0].box, [178.9, 60.9, 179.1, 61.1])
        assertBox(drawn.spots[1].box, [-179.1, 60.9, -178.9, 61.1])
        assertBox(drawn.spots[2].box, [179.9, 60.9, 180, 61.1])
        assertBox(drawn.spots[3].box, [-180, 60.9, -179.9, 61.1])
        XCTAssertEqual(drawn.spots.map(\.weight)[0...1], [30, 70])
        XCTAssertEqual(drawn.spots[2].weight + drawn.spots[3].weight, 40, accuracy: 1e-9)
        XCTAssertEqual(drawn.spots[2].weight, 20, accuracy: 0.01)
    }

    func testAFileThatIsNoMapDrawsNowhere() throws {
        let img = try map([("63000001", "RGN", [UInt8](repeating: 0, count: 16))])
        let drawn = RegionSuggestion.drawnGround(of: img)
        XCTAssertTrue(drawn.spots.isEmpty)
        XCTAssertFalse(RegionSuggestion.frame(of: img).isValid)
    }

    private func frame(_ tiles: [[Double]]) -> BBox {
        RegionSuggestion.frame(
            around: tiles.map { BBox(minLon: $0[0], minLat: $0[1], maxLon: $0[2], maxLat: $0[3]) }
        )
    }

    func testTheFrameIsTheRectangleAroundTheTiles() {
        assertBox(frame([[10, 50, 12, 51], [14, 49, 15, 52]]), [10, 49, 15, 52])
        XCTAssertFalse(frame([]).isValid)
    }

    /// Tiles either side of 180 deg, however each states its edges: the frame runs across,
    /// and is never the rest of the circle.
    func testAFrameAcross180RunsThroughIt() {
        assertBox(frame([[176, -20, 184, -15]]), [176, -20, 184, -15])
        assertBox(frame([[176, -20, 184, -15], [-178, -19, -170, -16]]), [176, -20, 190, -15])
        assertBox(frame([[170, 60, 180, 65], [-180, 61, -160, 66]]), [170, 60, 200, 66])
        // Far apart: the shorter way round is through 180 deg, the other through 0 deg.
        assertBox(frame([[-100, 10, -90, 20], [100, 10, 110, 20]]), [100, 10, 270, 20])
        assertBox(frame([[-60, 10, -50, 20], [50, 10, 60, 20]]), [-60, 10, 60, 20])
    }

    /// The share of a map its extracts hold is the share of its data, not of the ground
    /// its tiles span: a map of Andorra and Monaco has 1 tile stretched over the south of
    /// France between them.
    func testTheShareIsTheDataAnExtractHolds() throws {
        let img = try map([
            (
                "63000001", "TRE",
                TreFixture.tre(
                    bounds: BBox(minLon: 1.4, minLat: 42.4, maxLon: 7.6, maxLat: 43.8),
                    detail: [
                        .init(lon: 1.55, lat: 42.55, halfLon: 0.002, halfLat: 0.002, bytes: 900),
                        .init(lon: 7.42, lat: 43.73, halfLon: 0.002, halfLat: 0.002, bytes: 100)
                    ]
                )
            )
        ])
        func ground(_ name: String, _ b: [Double]) -> Region {
            let box = BBox(minLon: b[0], minLat: b[1], maxLon: b[2], maxLat: b[3])
            return Region(id: name, name: name, parentID: nil, pbfURL: nil, bbox: box, boxes: [box])
        }
        let andorra = ground("andorra", [1.4, 42.4, 1.8, 42.7]), monaco = ground("monaco", [7.40, 43.72, 7.44, 43.76])
        let drawn = RegionSuggestion.drawnGround(of: img)
        XCTAssertEqual(RegionSuggestion.share(of: drawn, on: [andorra]), 0.9, accuracy: 1e-9)
        XCTAssertEqual(RegionSuggestion.share(of: drawn, on: [andorra, monaco]), 1, accuracy: 1e-9)
        XCTAssertEqual(RegionSuggestion.share(of: drawn, on: [ground("between", [4, 42.8, 5, 43.4])]), 0)
        XCTAssertEqual(RegionSuggestion.share(of: drawn, on: []), 0)
    }
}
