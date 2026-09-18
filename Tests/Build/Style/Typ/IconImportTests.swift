import XCTest
@testable import kmap

/// Turning a picture on disk into a TYP drawing.
///
/// A TYP icon is a palette of at most 256 colours with one transparent slot and no alpha,
/// on a grid twenty pixels across. What has to be given up to fit is reported.
final class IconImportTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iconimport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.folder) }
    }

    /// A PNG with a red block top-left and a blue one bottom-right, the rest clear. The
    /// asymmetry catches a flipped icon. Written by `PNG` so it runs on every platform.
    @discardableResult
    private func makeCornerPNG(_ name: String, size: Int, block: Int = 4) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try PNG.corners(size: size, block: block).write(to: url)
        return url
    }

    // MARK: Which way up

    func testTheTopOfThePictureIsTheTopOfTheIcon() throws {
        let result = try IconImport.load(try makeCornerPNG("corners.png", size: 20), size: 20)
        let grid = try XCTUnwrap(result.block.pixels())

        XCTAssertEqual(grid[0][0], "#FF0000", "red belongs in the top-left")
        XCTAssertEqual(grid[19][19], "#0000FF", "blue belongs in the bottom-right")
        XCTAssertNil(grid[10][10], "the middle was never painted")
    }

    // MARK: Colours arriving as themselves

    /// Colours arrive unmanaged: drawing through a device colour space shifts them, and an
    /// icon's colours are matched against a palette exactly.
    func testAColourComesThroughExactlyAtTrueSize() throws {
        let result = try IconImport.load(try makeCornerPNG("exact.png", size: 20), size: 20)
        let colours = Set(result.block.palette.compactMap(\.colour))
        XCTAssertEqual(colours, ["#FF0000", "#0000FF"])
    }

    func testAPictureAlreadyTheRightSizeIsNotResampled() throws {
        let result = try IconImport.load(try makeCornerPNG("same.png", size: 20), size: 20)
        XCTAssertTrue(result.wasExactSize)
        XCTAssertEqual(result.softEdgePixels, 0, "nothing was scaled, so no edge was blurred")
        XCTAssertEqual(result.warnings, [], "nothing had to be given up")
    }

    // MARK: What is given up, and said

    func testScalingIsReportedRatherThanDoneQuietly() throws {
        let result = try IconImport.load(try makeCornerPNG("big.png", size: 64,
                                                           block: 13), size: 20)
        XCTAssertFalse(result.wasExactSize)
        XCTAssertEqual(result.sourceWidth, 64)
        XCTAssertTrue(result.warnings.contains { $0.contains("scaled from 64×64") },
                      "\(result.warnings)")
    }

    /// A TYP has one transparent colour and no alpha, so an antialiased rim is forced solid
    /// or clear; the number of pixels forced is reported.
    func testPartTransparentPixelsAreCountedAndForced() throws {
        let result = try IconImport.load(try makeCornerPNG("soft.png", size: 64,
                                                           block: 13), size: 20)
        XCTAssertGreaterThan(result.softEdgePixels, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("part-transparent") },
                      "\(result.warnings)")

        // Every pixel is now solid or clear.
        for row in try XCTUnwrap(result.block.pixels()) {
            for pixel in row where pixel != nil {
                XCTAssertTrue(pixel!.hasPrefix("#"))
            }
        }
    }

    // MARK: The palette ceiling

    /// A point image indexes its palette with at most eight bits, so 256 colours is the
    /// ceiling; a deeper picture is reduced and the reduction is reported.
    func testAPictureWithMoreColoursThanTheFormatAllowsIsCappedAndSaysSo() throws {
        let size = 20
        // 400 distinct colours on a 20×20 grid: one per pixel.
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for pixel in 0..<(size * size) {
            let i = pixel * 4
            rgba[i] = UInt8(pixel % size * 255 / (size - 1))
            rgba[i + 1] = UInt8(pixel / size * 255 / (size - 1))
            rgba[i + 2] = UInt8((pixel * 7) % size * 255 / (size - 1))
            rgba[i + 3] = 255
        }
        let url = folder.appendingPathComponent("many.png")
        try PNG.encode(width: size, height: size, rgba: rgba).write(to: url)

        let result = try IconImport.load(url, size: size)
        XCTAssertLessThanOrEqual(result.paletteSize, IconImport.maximumColours)
        XCTAssertEqual(result.block.declaredColours, result.block.palette.count)
    }

    /// Palette keys must be distinct, or the pixels of one colour resolve to another.
    func testEveryPaletteKeyIsDistinctHoweverDeepThePaletteGets() throws {
        let result = try IconImport.load(try makeCornerPNG("keys.png", size: 20), size: 20)
        let keys = result.block.palette.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.allSatisfy { $0.count == result.block.charsPerPixel })
    }

    // MARK: The drawing that comes out

    /// The imported drawing survives being written into a TYP and read back.
    func testTheDrawingWritesIntoATypAndReadsBackTheSame() throws {
        let result = try IconImport.load(try makeCornerPNG("round.png", size: 20), size: 20)

        let source = TypSource.parse("""
            [_point]
            Type=0x2a00
            DayXpm="1 1 1 1"
            "a c #000000"
            "a"
            String=0x00,Something
            [end]
            """)
        let edited = try TypEdit.setPicture(in: source, kind: .point, code: 0x2a00,
                                            to: result.block)
        let after = try XCTUnwrap(TypSource.parse(edited).section(.point, 0x2a00))

        XCTAssertEqual(after.picture?.pixels(), result.block.pixels())
        XCTAssertEqual(after.englishLabel, "Something", "the section's own text survives")
    }

    // MARK: Refusing

    func testAFileThatIsNotThereSaysSo() {
        XCTAssertThrowsError(try IconImport.load(folder.appendingPathComponent("ghost.png"),
                                                 size: 20))
    }

    func testAFileThatIsNotAPictureIsRefused() throws {
        let url = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(try IconImport.load(url, size: 20)) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not be read"),
                          error.localizedDescription)
        }
    }

    func testANonsenseSizeIsRefusedRatherThanAttempted() throws {
        let url = try makeCornerPNG("size.png", size: 20)
        XCTAssertThrowsError(try IconImport.load(url, size: 0))
        XCTAssertThrowsError(try IconImport.load(url, size: 300),
                             "a point image stores its width in one byte")
    }
}
