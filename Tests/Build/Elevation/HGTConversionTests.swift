import XCTest
@testable import kmap

/// Turning published GeoTIFF tiles into the `.hgt` grid everything downstream reads. A
/// `.hgt` is 3601 nodes square and covers its degree inclusive; a source tile is 3600
/// samples and stops one step short, so the last row and column come from the neighbours.
final class HGTConversionTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-hgtconv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let second = 1.0 / 3600.0

    /// A source tile the shape a published one has: samples on whole arc-seconds, its
    /// north-west corner on the degree, rows running south.
    private func source(cell: (lat: Int, lon: Int), width: Int, height: Int,
                        heights: (_ row: Int, _ column: Int) -> Float) throws -> URL {
        var fixture = TIFFFixture()
        fixture.width = width
        fixture.height = height
        fixture.bits = 32
        fixture.format = 3
        fixture.step = second
        fixture.origin = (lon: Double(cell.lon), lat: Double(cell.lat + 1))
        fixture.samples = (0..<height).flatMap { row in
            (0..<width).map { heights(row, $0) }
        }
        return try TIFFFixture.write(fixture, into: directory,
                                     as: "\(HGTName.of(lat: cell.lat, lon: cell.lon)).tif")
    }

    private func mosaic(_ files: [String: URL]) -> HGTConversion.Mosaic {
        HGTConversion.Mosaic { lat, lon in files[HGTName.of(lat: lat, lon: lon)] }
    }

    /// One node of a written `.hgt`, read back the way mkgmap reads it.
    private func height(_ data: Data, row: Int, column: Int) -> Int16 {
        let at = (row * 3601 + column) * 2
        return Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1]))
    }

    // MARK: What the mosaic answers

    func testACellWithNoFileIsNotAnErrorItIsSea() {
        // Most degree cells have no tile; a missing one reads as sea, not as an error.
        let empty = mosaic([:])
        XCTAssertNil(empty.tile(lat: 44, lon: 33))
        XCTAssertNil(empty.height(cellLat: 44, cellLon: 33, row: 0, column: 0))
    }

    func testATileIsOpenedOnceAndThenKept() throws {
        var asked = 0
        let url = try source(cell: (44, 33), width: 4, height: 4) { r, c in Float(r * 10 + c) }
        let held = HGTConversion.Mosaic { lat, lon in
            asked += 1
            return HGTName.of(lat: lat, lon: lon) == "N44E033" ? url : nil
        }
        XCTAssertNotNil(held.tile(lat: 44, lon: 33))
        XCTAssertNotNil(held.tile(lat: 44, lon: 33))
        XCTAssertNil(held.tile(lat: 10, lon: 10))
        XCTAssertNil(held.tile(lat: 10, lon: 10))
        // An absent cell is remembered too, so each is looked up once.
        XCTAssertEqual(asked, 2)
    }

    func testANodeSittingOnASampleIsThatSample() throws {
        let url = try source(cell: (44, 33), width: 4, height: 4) { r, c in Float(r * 100 + c) }
        let m = mosaic(["N44E033": url])
        XCTAssertEqual(m.height(cellLat: 44, cellLon: 33, row: 0, column: 0), 0)
        XCTAssertEqual(m.height(cellLat: 44, cellLon: 33, row: 0, column: 3), 3)
        XCTAssertEqual(m.height(cellLat: 44, cellLon: 33, row: 2, column: 1), 201)
    }

    func testTheSouthernRowComesFromTheCellBelowAndNotFromThisOne() throws {
        // The seam rule: row 3600 of a cell is row 0 of the cell below it.
        let here = try source(cell: (44, 33), width: 4, height: 4) { _, _ in 500 }
        let below = try source(cell: (43, 33), width: 4, height: 4) { _, _ in 900 }
        let m = mosaic(["N44E033": here, "N43E033": below])
        XCTAssertEqual(m.height(cellLat: 44, cellLon: 33, row: 3600, column: 0), 900)
        XCTAssertEqual(m.height(cellLat: 44, cellLon: 33, row: 0, column: 0), 500)
    }

    func testTheEasternColumnComesFromTheCellToTheRight() throws {
        let here = try source(cell: (44, 33), width: 4, height: 4) { _, _ in 500 }
        let east = try source(cell: (44, 34), width: 4, height: 4) { _, _ in 700 }
        let m = mosaic(["N44E033": here, "N44E034": east])
        XCTAssertEqual(m.height(cellLat: 44, cellLon: 33, row: 0, column: 3600), 700)
    }

    func testTheCornerComesFromTheTileDiagonallyAcross() throws {
        let here = try source(cell: (44, 33), width: 4, height: 4) { _, _ in 500 }
        let across = try source(cell: (43, 34), width: 4, height: 4) { _, _ in 111 }
        let m = mosaic(["N44E033": here, "N43E034": across])
        XCTAssertEqual(m.height(cellLat: 44, cellLon: 33, row: 3600, column: 3600), 111)
    }

    func testANodeBetweenTwoSamplesIsTheAverageOfThem() throws {
        // Only where the source is thinned: above 50° Copernicus samples every 1.5".
        var fixture = TIFFFixture()
        fixture.width = 3; fixture.height = 3
        fixture.bits = 32; fixture.format = 3
        fixture.step = second * 2                       // a sample every two seconds
        fixture.origin = (lon: 33, lat: 56)
        fixture.samples = [100, 200, 300, 0, 0, 0, 0, 0, 0]
        let url = try TIFFFixture.write(fixture, into: directory, as: "N55E033.tif")
        let m = mosaic(["N55E033": url])
        XCTAssertEqual(m.height(cellLat: 55, cellLon: 33, row: 0, column: 0), 100)
        XCTAssertEqual(m.height(cellLat: 55, cellLon: 33, row: 0, column: 1), 150)
        XCTAssertEqual(m.height(cellLat: 55, cellLon: 33, row: 0, column: 2), 200)
    }

    // MARK: The written file

    /// A source a whole degree tall but only a few samples wide: enough for the fast
    /// row-at-a-time path to run for every row without building 12 million samples.
    private func tallSource(cell: (lat: Int, lon: Int), width: Int,
                            heights: @escaping (_ row: Int, _ column: Int) -> Float) throws -> URL {
        try source(cell: cell, width: width, height: 3600, heights: heights)
    }

    func testTheFileIsTheShapeAndByteOrderMkgmapReads() throws {
        let url = try tallSource(cell: (44, 33), width: 8) { r, c in Float(r + c) }
        let out = directory.appendingPathComponent("N44E033.hgt")
        let written = try HGTConversion.write(cell: (lat: 44, lon: 33),
                                              from: mosaic(["N44E033": url]), to: out)
        let data = try Data(contentsOf: out)
        // 3601² big-endian 16-bit, whatever was covered.
        XCTAssertEqual(data.count, 3601 * 3601 * 2)
        XCTAssertGreaterThan(written, 0)
        // Northmost row first: node (0,0) is the north-west corner of the degree.
        XCTAssertEqual(height(data, row: 0, column: 0), 0)
        XCTAssertEqual(height(data, row: 0, column: 7), 7)
        XCTAssertEqual(height(data, row: 5, column: 2), 7)
        // Nothing was written where nothing covered it, rather than a guess.
        XCTAssertEqual(height(data, row: 0, column: 3000), 0)
    }

    func testHeightsAreRoundedHalvesAwayFromZeroAsGDALDoes() throws {
        // Matches `gdal_translate -ot Int16`: halves away from zero, and a negative height
        // written as a signed value rather than a large unsigned one.
        let values: [Float] = [0.5, 1.5, -0.5, -3.5, 2.4, 2.6, -2.4, -2.6, -430]
        let url = try tallSource(cell: (44, 33), width: values.count) { r, c in
            r == 0 ? values[c] : 0
        }
        let out = directory.appendingPathComponent("round.hgt")
        try HGTConversion.write(cell: (lat: 44, lon: 33),
                                from: mosaic(["N44E033": url]), to: out)
        let data = try Data(contentsOf: out)
        XCTAssertEqual((0..<values.count).map { height(data, row: 0, column: $0) },
                       [1, 2, -1, -4, 2, 3, -2, -3, -430])
    }

    func testACellNothingCoversIsRefusedRatherThanWrittenFlat() throws {
        // A file of 3601² zeroes is a degree of sea level, and the DEM layer would draw it.
        let out = directory.appendingPathComponent("empty.hgt")
        XCTAssertThrowsError(try HGTConversion.write(cell: (lat: 44, lon: 33),
                                                     from: mosaic([:]), to: out)) { error in
            XCTAssertEqual("\(error)", "no elevation data covering N44E033")
        }
        XCTAssertFalse(FileTools.exists(out))
    }

    // MARK: The three arc-second grid (GLO-90)

    /// Like source(), at GLO-90's base sampling: three arc-seconds both ways.
    private func source90(cell: (lat: Int, lon: Int), width: Int, height: Int,
                          lonStepSeconds: Double = 3,
                          heights: (_ row: Int, _ column: Int) -> Float) throws -> URL {
        var fixture = TIFFFixture()
        fixture.width = width
        fixture.height = height
        fixture.bits = 32
        fixture.format = 3
        fixture.step = lonStepSeconds * second
        fixture.stepLat = 3 * second
        fixture.origin = (lon: Double(cell.lon), lat: Double(cell.lat + 1))
        fixture.samples = (0..<height).flatMap { row in
            (0..<width).map { heights(row, $0) }
        }
        return try TIFFFixture.write(fixture, into: directory,
                                     as: "\(HGTName.of(lat: cell.lat, lon: cell.lon)).tif")
    }

    private func height1201(_ data: Data, row: Int, column: Int) -> Int16 {
        let at = (row * 1201 + column) * 2
        return Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1]))
    }

    func testAThreeArcSecondNodeSitsExactlyOnItsSample() throws {
        // A three-arc-second tile and a 1201-node `.hgt` step alike, so node (r, c) is
        // sample (r, c): no interpolation and no rounding.
        let tile = try source90(cell: (44, 33), width: 8, height: 8) { row, column in
            Float(row * 100 + column) + 7
        }
        let out = directory.appendingPathComponent("out.hgt")
        try HGTConversion.write(cell: (44, 33), from: mosaic(["N44E033": tile]),
                                to: out, nodes: 1201)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.count, 1201 * 1201 * 2, "a 3\" cell is 1201 nodes square")
        XCTAssertEqual(height1201(data, row: 0, column: 0), 7)
        XCTAssertEqual(height1201(data, row: 3, column: 5), 312)
        XCTAssertEqual(height1201(data, row: 7, column: 2), 709)
    }

    func testTheOneArcSecondPathIsUntouchedByTheParameter() throws {
        // The 1" conversion runs the same arithmetic whether or not `nodes` is given.
        let tile = try source(cell: (44, 33), width: 6, height: 6) { row, column in
            Float(row * 10 + column)
        }
        let defaulted = directory.appendingPathComponent("default.hgt")
        let explicit = directory.appendingPathComponent("explicit.hgt")
        try HGTConversion.write(cell: (44, 33), from: mosaic(["N44E033": tile]), to: defaulted)
        try HGTConversion.write(cell: (44, 33), from: mosaic(["N44E033": tile]),
                                to: explicit, nodes: 3601)
        XCTAssertEqual(try Data(contentsOf: defaulted), try Data(contentsOf: explicit))
    }

    func testTheThinnedBandInterpolatesOnExactThirds() throws {
        // Between 50° and 60° longitude widens to 4.5" while latitude stays at 3", so node
        // column 1 falls two thirds from sample 0 to sample 1: 30 + (60-30)*2/3 = 50.
        let tile = try source90(cell: (55, 37), width: 8, height: 8,
                                lonStepSeconds: 4.5) { row, column in
            Float(30 + column * 30 + row * 1000)
        }
        let out = directory.appendingPathComponent("thinned.hgt")
        try HGTConversion.write(cell: (55, 37), from: mosaic(["N55E037": tile]),
                                to: out, nodes: 1201)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(height1201(data, row: 0, column: 0), 30, "on the sample")
        XCTAssertEqual(height1201(data, row: 0, column: 1), 50, "two thirds along")
        XCTAssertEqual(height1201(data, row: 0, column: 2), 70, "one third along")
        XCTAssertEqual(height1201(data, row: 0, column: 3), 90, "back on a sample")
        // The next row of nodes is the next source row: latitude is never thinned.
        XCTAssertEqual(height1201(data, row: 1, column: 0), 1030)
    }

    func testTheFarNorthBandAtSixSecondsInterpolatesByHalves() throws {
        // North of 60° the spacing is 6", so every second node is a sample and those
        // between are midpoints, rounded half away from zero.
        let tile = try source90(cell: (62, -7), width: 6, height: 6,
                                lonStepSeconds: 6) { row, column in
            Float(100 + column * 11 + row * 1000)
        }
        let out = directory.appendingPathComponent("north.hgt")
        try HGTConversion.write(cell: (62, -7), from: mosaic(["N62W007": tile]),
                                to: out, nodes: 1201)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(height1201(data, row: 0, column: 0), 100)
        XCTAssertEqual(height1201(data, row: 0, column: 2), 111)
        XCTAssertEqual(height1201(data, row: 0, column: 1), 106, "105.5 rounds away from zero")
    }

    func testTheEasternColumnOfAThreeArcSecondCellComesFromTheNeighbour() throws {
        // The 1201st column sits on the next degree: the neighbour's first column.
        let west = try source90(cell: (44, 33), width: 1200, height: 4) { _, _ in 5 }
        let east = try source90(cell: (44, 34), width: 4, height: 4) { _, _ in 9 }
        let out = directory.appendingPathComponent("seam.hgt")
        try HGTConversion.write(cell: (44, 33),
                                from: mosaic(["N44E033": west, "N44E034": east]),
                                to: out, nodes: 1201)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(height1201(data, row: 0, column: 1199), 5)
        XCTAssertEqual(height1201(data, row: 0, column: 1200), 9,
                       "the last node is the neighbour's first sample")
    }


    // MARK: Where the sampling bands meet

    func testTheSouthernRowOfAThinnedCellComesFromTheDenserBandBelow() throws {
        // Two lattices meet on the shared row: a 4.5" cell over a 3" one. The row is read
        // exactly from the denser cell below, whose samples every node lands on.
        let north = try source90(cell: (50, 37), width: 8, height: 8,
                                 lonStepSeconds: 4.5) { _, _ in 1 }
        let south = try source90(cell: (49, 37), width: 8, height: 8) { row, column in
            row == 0 ? Float(500 + column) : 2
        }
        let out = directory.appendingPathComponent("band-seam.hgt")
        try HGTConversion.write(cell: (50, 37),
                                from: mosaic(["N50E037": north, "N49E037": south]),
                                to: out, nodes: 1201)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(height1201(data, row: 1200, column: 0), 500)
        XCTAssertEqual(height1201(data, row: 1200, column: 3), 503)
        // The fixture covers only the top rows, so the cell's own band is asserted there.
        XCTAssertEqual(height1201(data, row: 1, column: 0), 1,
                       "away from the seam the cell's own band answers")
    }

    func testTheSixtyDegreeBoundaryMeetsTheSameWay() throws {
        // The same seam one band up: a 6" cell over a 4.5" one, so only every third node
        // is exact and node 1 interpolates: 600 + (609-600)*2/3 = 606.
        let north = try source90(cell: (60, 25), width: 6, height: 6,
                                 lonStepSeconds: 6) { _, _ in 1 }
        let south = try source90(cell: (59, 25), width: 8, height: 8,
                                 lonStepSeconds: 4.5) { row, column in
            row == 0 ? Float(600 + column * 9) : 2
        }
        let out = directory.appendingPathComponent("sixty-seam.hgt")
        try HGTConversion.write(cell: (60, 25),
                                from: mosaic(["N60E025": north, "N59E025": south]),
                                to: out, nodes: 1201)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(height1201(data, row: 1200, column: 0), 600, "on N59's sample")
        XCTAssertEqual(height1201(data, row: 1200, column: 1), 606, "two thirds between")
        XCTAssertEqual(height1201(data, row: 1200, column: 2), 612, "one third between")
        XCTAssertEqual(height1201(data, row: 1200, column: 3), 618, "back on a sample")
    }

    func testTheOneArcSecondBandBoundaryStillMeetsExactly() throws {
        // The same seam on the 1" grid: a 1.5" cell over a 1" one, the shared row read
        // exactly from below.
        var thinned = TIFFFixture()
        thinned.width = 8; thinned.height = 8
        thinned.bits = 32; thinned.format = 3
        thinned.step = 1.5 * second
        thinned.stepLat = second
        thinned.origin = (lon: 37.0, lat: 51.0)
        thinned.samples = (0..<64).map { _ in Float(1) }
        let north = try TIFFFixture.write(thinned, into: directory, as: "N50E037.tif")
        let south = try source(cell: (49, 37), width: 8, height: 8) { row, column in
            row == 0 ? Float(700 + column) : 2
        }
        let out = directory.appendingPathComponent("band-seam-1s.hgt")
        try HGTConversion.write(cell: (50, 37),
                                from: mosaic(["N50E037": north, "N49E037": south]), to: out)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(height(data, row: 3600, column: 0), 700)
        XCTAssertEqual(height(data, row: 3600, column: 5), 705)
        XCTAssertEqual(height(data, row: 1, column: 0), 1)
    }

}
