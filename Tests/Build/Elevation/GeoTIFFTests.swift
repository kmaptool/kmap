import XCTest
@testable import kmap

/// Reading an elevation tile without GDAL. Copernicus publishes Float32, DEFLATE,
/// predictor 3, point-registered, in 1024-pixel tiles; ALOS publishes Int16, uncompressed,
/// a row to a strip, registered on cell areas — half a step off the nodes.
final class GeoTIFFTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-tiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: A file built by hand

    private typealias Fixture = TIFFFixture

    private func write(_ fixture: Fixture, as name: String = "tile.tif") throws -> URL {
        try TIFFFixture.write(fixture, into: directory, as: name)
    }

    private func ramp(_ width: Int, _ height: Int) -> [Float] {
        (0..<(width * height)).map { Float($0 * 10) }
    }

    // MARK: Reading one

    func testTheSamplesComeBackWhereTheyWerePut() throws {
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertEqual(tiff.width, 4)
        XCTAssertEqual(tiff.height, 3)
        for row in 0..<3 {
            XCTAssertEqual(try tiff.row(row), (0..<4).map { Float((row * 4 + $0) * 10) })
            for column in 0..<4 {
                XCTAssertEqual(try tiff.value(row: row, column: column),
                               Float((row * 4 + column) * 10))
            }
        }
    }

    func testAskingOutsideTheRasterAnswersNothingRatherThanRubbish() throws {
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertNil(try tiff.value(row: -1, column: 0))
        XCTAssertNil(try tiff.value(row: 3, column: 0))
        XCTAssertNil(try tiff.value(row: 0, column: 4))
        XCTAssertNil(try tiff.value(row: 0, column: -1))
        XCTAssertTrue(try tiff.row(3).isEmpty)
    }

    func testAPointRegisteredFileIsReadAtItsStatedCorner() throws {
        // What Copernicus publishes: the tiepoint is the sample itself.
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertEqual(tiff.originLon, 33.0, accuracy: 1e-12)
        XCTAssertEqual(tiff.originLat, 45.0, accuracy: 1e-12)
        XCTAssertEqual(tiff.stepLon, 0.25, accuracy: 1e-12)
        // Rows run southwards.
        XCTAssertEqual(tiff.stepLat, -0.25, accuracy: 1e-12)
    }

    func testAnAreaRegisteredFileIsShiftedHalfAStepOntoItsSamples() throws {
        // What ALOS publishes; read as point-registered it shifts everything half a pixel.
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        fixture.rasterType = 1
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertEqual(tiff.originLon, 33.125, accuracy: 1e-12)
        XCTAssertEqual(tiff.originLat, 44.875, accuracy: 1e-12)
    }

    // MARK: The shapes a file comes in

    func testATiledFileReadsTheSameAsAStrippedOne() throws {
        var stripped = Fixture()
        stripped.width = 6; stripped.height = 5; stripped.samples = ramp(6, 5)
        var tiled = stripped
        tiled.tile = (width: 4, height: 4)          // two across, two down, both ragged
        let a = try GeoTIFF(contentsOf: try write(stripped, as: "a.tif"))
        let b = try GeoTIFF(contentsOf: try write(tiled, as: "b.tif"))
        for row in 0..<5 {
            XCTAssertEqual(try a.row(row), try b.row(row), "row \(row)")
        }
    }

    func testSeveralStripsAreJoinedBackIntoOneImage() throws {
        var fixture = Fixture()
        fixture.width = 4; fixture.height = 6; fixture.samples = ramp(4, 6)
        fixture.tile = (width: 4, height: 2)        // three strips
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertEqual(try tiff.row(5), [200, 210, 220, 230])
    }

    func testAFloatingPointFileIsReadAsWrittenIncludingItsFractions() throws {
        var fixture = Fixture()
        fixture.bits = 32; fixture.format = 3
        fixture.samples = [1.5, -2.25, 1000.75, 0, -0.5, 8_848.5, 3, 4, 5, 6, 7, 8]
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertEqual(try tiff.row(0), [1.5, -2.25, 1000.75, 0])
        XCTAssertEqual(try tiff.value(row: 1, column: 1), 8_848.5)
    }

    func testNegativeHeightsSurviveASixteenBitFile() throws {
        // A height below sea level: read unsigned it would be 65 106.
        var fixture = Fixture()
        fixture.samples = [-430, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertEqual(try tiff.row(0), [-430, -1, 0, 1])
    }

    func testABigEndianFileIsReadTheSameWayRoundAsALittleEndianOne() throws {
        var little = Fixture()
        little.samples = ramp(4, 3)
        var big = little
        big.bigEndian = true
        let a = try GeoTIFF(contentsOf: try write(little, as: "l.tif"))
        let b = try GeoTIFF(contentsOf: try write(big, as: "b.tif"))
        XCTAssertEqual(try a.row(1), try b.row(1))
        XCTAssertEqual(a.originLon, b.originLon, accuracy: 1e-12)
    }

    // MARK: Predictors

    func testTheHorizontalPredictorIsUndoneSampleBySample() throws {
        // Predictor 2 differences samples, not bytes: a 16-bit band is reassembled
        // before the sum.
        var fixture = Fixture()
        fixture.predictor = 2
        fixture.samples = [100, 500, 300, -50, 0, 1, 2, 3, 4, 5, 6, 7]
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertEqual(try tiff.row(0), [100, 500, 300, -50])
        XCTAssertEqual(try tiff.row(1), [0, 1, 2, 3])
    }

    func testTheFloatingPointPredictorIsUndoneInBothItsPasses() throws {
        // Predictor 3 shuffles the bytes into columns and then differences them, so
        // undoing it is the sum and then the gather.
        var fixture = Fixture()
        fixture.bits = 32; fixture.format = 3; fixture.predictor = 3
        fixture.samples = [1.5, 900.25, -12.5, 0, 4, 5, 6, 7, 8, 9, 10, 11]
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertEqual(try tiff.row(0), [1.5, 900.25, -12.5, 0])
        XCTAssertEqual(try tiff.row(2), [8, 9, 10, 11])
    }

    // MARK: What it will not read

    func testSomethingThatIsNotATIFFIsRefusedByName() throws {
        let url = directory.appendingPathComponent("nope.tif")
        try Data("this is not a tiff at all, not even close".utf8).write(to: url)
        XCTAssertThrowsError(try GeoTIFF(contentsOf: url)) { error in
            XCTAssertEqual("\(error)", "not a TIFF file")
        }
        try Data([0x49, 0x49]).write(to: url)          // right mark, nothing behind it
        XCTAssertThrowsError(try GeoTIFF(contentsOf: url))
    }

    func testBigTIFFIsRefusedAsBigTIFFRatherThanAsRubbish() throws {
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        fixture.magic = 43
        XCTAssertThrowsError(try GeoTIFF(contentsOf: try write(fixture))) { error in
            XCTAssertEqual("\(error)", "BigTIFF, which this reader does not do")
        }
    }

    func testAFileWithMoreThanOneBandIsRefused() throws {
        // Elevation is one band; reading three as one interleaves the channels.
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        fixture.bands = 3
        XCTAssertThrowsError(try GeoTIFF(contentsOf: try write(fixture))) { error in
            XCTAssertTrue("\(error)".contains("more than one band"), "\(error)")
        }
    }

    func testAnUnreadableSampleWidthIsRefusedRatherThanGuessedAt() throws {
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        fixture.bits = 8
        XCTAssertThrowsError(try GeoTIFF(contentsOf: try write(fixture))) { error in
            XCTAssertTrue("\(error)".contains("8 bits"), "\(error)")
        }
    }

    func testAFileMissingItsPlaceOnEarthIsRefused() throws {
        // Without the tiepoint nothing says which degree the samples cover.
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        fixture.placed = false
        XCTAssertThrowsError(try GeoTIFF(contentsOf: try write(fixture))) { error in
            XCTAssertTrue("\(error)".contains("geo-referencing"), "\(error)")
        }
    }
}
