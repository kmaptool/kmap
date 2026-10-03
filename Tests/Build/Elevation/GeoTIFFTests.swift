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
                XCTAssertEqual(
                    try tiff.value(row: row, column: column),
                    Float((row * 4 + column) * 10)
                )
            }
        }
    }

    /// Rewrites one u32 tag value in a written file: the fixture only writes sane headers.
    private func patchTag(_ url: URL, tag: Int, value: UInt32) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        let big = bytes[0] == 0x4D
        func u16(_ at: Int) -> Int {
            big ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) -> Int { big ? u16(at) << 16 | u16(at + 2) : u16(at) | u16(at + 2) << 16 }
        let directory = u32(4)
        let count = u16(directory)
        for i in 0..<count {
            let entry = directory + 2 + i * 12
            guard u16(entry) == tag else { continue }
            let out =
                big
                ? [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
                : [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
            bytes.replaceSubrange((entry + 8)..<(entry + 12), with: out)
            try FileTools.write(Data(bytes), to: url)
            return
        }
        XCTFail("tag \(tag) not in the file")
    }

    func testAZeroTileWidthIsRefusedRatherThanDividingByIt() throws {
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        fixture.tile = (width: 2, height: 2)
        let url = try write(fixture)
        try patchTag(url, tag: 322, value: 0)
        XCTAssertThrowsError(try GeoTIFF(contentsOf: url))
    }

    func testATileWiderAndTallerThanTheImageIsReadAsPadded() throws {
        // The DEM tiles north of 80 deg are 720 samples wide in tiles of 1024.
        var plain = Fixture()
        plain.width = 5
        plain.height = 3
        plain.bits = 32
        plain.format = 3
        plain.predictor = 3
        plain.samples = ramp(5, 3)
        var padded = plain
        padded.tile = (width: 16, height: 16)
        let expected = try GeoTIFF(contentsOf: try write(plain, as: "plain.tif"))
        let tiff = try GeoTIFF(contentsOf: try write(padded, as: "padded.tif"))
        for row in 0..<3 {
            for column in 0..<5 {
                XCTAssertEqual(try tiff.value(row: row, column: column), try expected.value(row: row, column: column))
            }
        }
    }

    func testATileTooLargeToHoldIsRefusedWithoutOverflowing() throws {
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        fixture.tile = (width: 2, height: 2)
        let url = try write(fixture)
        try patchTag(url, tag: 322, value: UInt32.max)
        try patchTag(url, tag: 323, value: UInt32.max)
        XCTAssertThrowsError(try GeoTIFF(contentsOf: url))
    }

    func testAStripCountPastAnyRasterMeansOneStrip() throws {
        // Some writers put 2^32 - 1 in RowsPerStrip for a single-strip file. That used
        // to size a tile buffer of width x 4G samples before anything was checked.
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        let url = try write(fixture)
        try patchTag(url, tag: 278, value: UInt32.max)
        let tiff = try GeoTIFF(contentsOf: url)
        XCTAssertEqual(try tiff.value(row: 2, column: 3), 110)
    }

    func testATileClaimingMoreRowsThanItsBytesHoldIsRefusedAtTheRead() throws {
        // Taller than the raster is allowed, padding is; bytes that fall short are not.
        var fixture = Fixture()
        fixture.samples = ramp(4, 3)
        fixture.tile = (width: 2, height: 2)
        let url = try write(fixture)
        try patchTag(url, tag: 323, value: 1 << 20)
        let tiff = try GeoTIFF(contentsOf: url)
        XCTAssertThrowsError(try tiff.value(row: 0, column: 0))
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
        tiled.tile = (width: 4, height: 4)  // two across, two down, both ragged
        let a = try GeoTIFF(contentsOf: try write(stripped, as: "a.tif"))
        let b = try GeoTIFF(contentsOf: try write(tiled, as: "b.tif"))
        for row in 0..<5 {
            XCTAssertEqual(try a.row(row), try b.row(row), "row \(row)")
        }
    }

    func testSeveralStripsAreJoinedBackIntoOneImage() throws {
        var fixture = Fixture()
        fixture.width = 4; fixture.height = 6; fixture.samples = ramp(4, 6)
        fixture.tile = (width: 4, height: 2)  // three strips
        let tiff = try GeoTIFF(contentsOf: try write(fixture))
        XCTAssertEqual(try tiff.row(5), [200, 210, 220, 230])
    }

    /// 5 rows in strips of 2 end in a strip of 1: read whole, at both sizes and predictors.
    func testAShortLastStripIsReadToTheImagesLastRow() throws {
        for (bits, format, predictor) in [(16, 2, 1), (32, 3, 1), (32, 3, 2), (16, 2, 2)] {
            var fixture = Fixture()
            fixture.width = 4; fixture.height = 5; fixture.samples = ramp(4, 5)
            fixture.bits = bits; fixture.format = format; fixture.predictor = predictor
            fixture.rowsPerStrip = 2
            let tiff = try GeoTIFF(contentsOf: try write(fixture, as: "short-\(bits)-\(predictor).tif"))
            for row in 0..<5 {
                XCTAssertEqual(try tiff.row(row), Array(fixture.samples[(row * 4)..<(row * 4 + 4)]), "row \(row)")
            }
            XCTAssertNil(try tiff.value(row: 5, column: 0), "past the image, not the strip's padding")
        }
    }

    /// A strip shorter than the rows the image has left is still refused.
    func testAStripShortOfTheImagesRowsIsRefused() throws {
        var fixture = Fixture()
        fixture.width = 4; fixture.height = 5; fixture.samples = ramp(4, 5)
        fixture.rowsPerStrip = 2
        let url = try write(fixture)
        // RowsPerStrip raised to 4: the first strip, of 2 rows, now holds too few.
        try patchTag(url, tag: 278, value: 4)
        let tiff = try GeoTIFF(contentsOf: url)
        XCTAssertThrowsError(try tiff.value(row: 0, column: 0))
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

    func testTheHorizontalPredictorUndoesFloatWordsAsIntegers() throws {
        // FABDEM and GEDTM30 write float32 under predictor 2: the words are differenced
        // as integers, so a sum of floats would give the wrong heights.
        for bigEndian in [false, true] {
            var fixture = Fixture()
            fixture.bits = 32; fixture.format = 3; fixture.predictor = 2; fixture.bigEndian = bigEndian
            fixture.samples = [1.5, 900.25, -12.5, 0, 3806.5, -9999, 0.125, 7, 8, 9, 10, 11]
            let tiff = try GeoTIFF(contentsOf: try write(fixture, as: "p2-\(bigEndian).tif"))
            XCTAssertEqual(try tiff.row(0), [1.5, 900.25, -12.5, 0], "big endian \(bigEndian)")
            XCTAssertEqual(try tiff.row(1), [3806.5, -9999, 0.125, 7], "big endian \(bigEndian)")
        }
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
        try FileTools.write(Data("this is not a tiff at all, not even close".utf8), to: url)
        XCTAssertThrowsError(try GeoTIFF(contentsOf: url)) { error in
            XCTAssertEqual("\(error)", "not a TIFF file")
        }
        try FileTools.write(Data([0x49, 0x49]), to: url)  // right mark, nothing behind it
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

    /// The vector undoing of predictor 3 against the plain one, at widths that end a
    /// vector exactly, fall short of one and run past several.
    func testTheFloatPredictorIsUndoneTheSameWayAVectorAtATime() {
        var random = SplitMix64(state: 20_261_006)
        for width in [1, 2, 3, 4, 5, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 512] {
            let rows = 3
            let raw = (0..<(width * 4 * rows)).map { _ in UInt8.random(in: 0...255, using: &random) }
            var plainBytes = raw
            var plain = [Float](repeating: 0, count: width * rows)
            plainBytes.withUnsafeMutableBufferPointer { bytes in
                plain.withUnsafeMutableBufferPointer {
                    GeoTIFF.floatRows(bytes.baseAddress!, width: width, rows: rows, into: $0.baseAddress!)
                }
            }
            VectorTiers.each { tier in
                var vectorBytes = raw
                var vector = [Float](repeating: 0, count: width * rows)
                let done = vectorBytes.withUnsafeMutableBufferPointer { bytes in
                    vector.withUnsafeMutableBufferPointer {
                        GeoTIFF.vectorFloatRows(bytes.baseAddress!, width: width, rows: rows, into: $0.baseAddress!)
                    }
                }
                XCTAssertEqual(done, tier > 0, "tier \(tier): only the lowest does nothing")
                guard done else { return }
                XCTAssertEqual(vector.map(\.bitPattern), plain.map(\.bitPattern), "width \(width), tier \(tier)")
                XCTAssertEqual(vectorBytes, plainBytes, "width \(width), tier \(tier): the sums left in place")
            }
        }
    }
}
