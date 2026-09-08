import XCTest
@testable import kmap

/// Covers decoding a picture and resampling it onto another grid.
///
/// A decoded picture keeps its orientation, and resampling a soft edge does not drag the
/// colour of transparent pixels into it.
final class RasterTests: XCTestCase {

    private func bitmap(_ width: Int, _ height: Int,
                        _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> Raster.Bitmap {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b; rgba[i + 3] = a
            }
        }
        return Raster.Bitmap(width: width, height: height, rgba: rgba)
    }

    // MARK: Decoding

    func testAPngComesBackWithItsCornersWhereTheyWerePut() throws {
        let data = PNG.corners(size: 8, block: 2)
        let image = try XCTUnwrap(Raster.decode(Array(data)))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 8)
        XCTAssertEqual(image[0, 0].r, 255, "red in the top-left")
        XCTAssertEqual(image[0, 0].b, 0)
        XCTAssertEqual(image[7, 7].b, 255, "blue in the bottom-right")
        XCTAssertEqual(image[7, 7].r, 0)
        XCTAssertEqual(image[4, 4].a, 0, "the middle was never painted")
    }

    func testAColourIsNotColourManagedOnTheWayIn() {
        // #FF0000 must arrive as #FF0000: through a device colour space it becomes
        // #FF2600 and no longer matches a palette entry.
        let data = PNG.encode(width: 1, height: 1, rgba: [255, 0, 0, 255])
        let image = Raster.decode(Array(data))
        XCTAssertEqual(image?.rgba, [255, 0, 0, 255])
    }

    func testSomethingThatIsNotAPictureIsRefused() {
        XCTAssertNil(Raster.decode(Array("hello, this is not a picture".utf8)))
        XCTAssertNil(Raster.decode([]))
        XCTAssertNil(Raster.decode([0x89, 0x50, 0x4E, 0x47]), "a signature and nothing after it")
    }

    func testATruncatedPngIsRefusedRatherThanHalfDecoded() {
        let data = Array(PNG.corners(size: 16, block: 4))
        XCTAssertNil(Raster.decode(Array(data.prefix(data.count / 2))))
    }

    func testTheDimensionsAreReadableWithoutDecodingTheWholeThing() {
        let data = Array(PNG.corners(size: 12, block: 3))
        let size = Raster.dimensions(data)
        XCTAssertEqual(size?.width, 12)
        XCTAssertEqual(size?.height, 12)
        XCTAssertNil(Raster.dimensions(Array("not a picture".utf8)))
    }

    // MARK: Resampling

    func testAPictureAlreadyTheRightSizeComesBackByteForByte() {
        // Any filter at 1:1 would soften every edge for nothing.
        let source = bitmap(20, 20) { x, y in (UInt8(x * 12), UInt8(y * 12), 7, 255) }
        XCTAssertEqual(Raster.resampled(source, toSquare: 20), source)
    }

    func testShrinkingAveragesRatherThanPickingOnePixelOutOfMany() {
        // Half red, half blue reduced to one pixel: the mean, not either colour.
        let source = bitmap(64, 64) { x, _ in x < 32 ? (255, 0, 0, 255) : (0, 0, 255, 255) }
        let one = Raster.resampled(source, toSquare: 1)
        XCTAssertEqual(one.width, 1)
        XCTAssertEqual(one[0, 0].r, 128, accuracy: 2)
        XCTAssertEqual(one[0, 0].b, 128, accuracy: 2)
    }

    func testShrinkingKeepsWhichWayUpThePictureIs() {
        let source = bitmap(40, 40) { _, y in y < 20 ? (255, 0, 0, 255) : (0, 0, 255, 255) }
        let small = Raster.resampled(source, toSquare: 4)
        XCTAssertEqual(small[0, 0].r, 255, "the red half was on top and stays on top")
        XCTAssertEqual(small[0, 3].b, 255)
    }

    func testATransparentSurroundDoesNotBleedIntoTheShape() {
        // The filter premultiplies; averaging without alpha would drag the black of the
        // transparent pixels into the rim of the disc.
        let source = bitmap(32, 32) { x, y in
            let dx = Double(x) - 15.5, dy = Double(y) - 15.5
            return (dx * dx + dy * dy) < 100 ? (255, 0, 0, 255) : (0, 0, 0, 0)
        }
        let small = Raster.resampled(source, toSquare: 8)
        for y in 0..<8 {
            for x in 0..<8 where small[x, y].a > 0 {
                XCTAssertEqual(small[x, y].g, 0, "no green appeared at (\(x),\(y))")
                XCTAssertEqual(small[x, y].b, 0, "no blue appeared at (\(x),\(y))")
                XCTAssertGreaterThan(small[x, y].r, 200,
                                     "the red stayed red at (\(x),\(y)), rather than darkening")
            }
        }
    }

    func testAnOpaquePictureStaysOpaque() {
        let source = bitmap(30, 30) { x, y in (UInt8(x * 8), UInt8(y * 8), 0, 255) }
        let small = Raster.resampled(source, toSquare: 10)
        for y in 0..<10 {
            for x in 0..<10 { XCTAssertEqual(small[x, y].a, 255) }
        }
    }

    func testGrowingInterpolatesRatherThanBlocking() {
        // Averaging a region smaller than a pixel degenerates to nearest-neighbour, so
        // growing takes the interpolating filter.
        let source = bitmap(2, 1) { x, _ in x == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        let big = Raster.resampled(source, width: 8, height: 1)
        let middle = (0..<8).map { big[$0, 0].r }
        XCTAssertEqual(middle.first, 0)
        XCTAssertEqual(middle.last, 255)
        XCTAssertTrue(middle.contains { $0 > 0 && $0 < 255 }, "\(middle)")
        XCTAssertEqual(middle, middle.sorted(), "and it climbs, rather than wandering")
    }

    func testANonSquareSourceIsStretchedOntoTheSquare() {
        // Stretched, not letterboxed; the importer warns about the aspect change.
        let source = bitmap(40, 10) { _, _ in (10, 20, 30, 255) }
        let square = Raster.resampled(source, toSquare: 20)
        XCTAssertEqual(square.width, 20)
        XCTAssertEqual(square.height, 20)
        XCTAssertEqual(square[10, 10].g, 20)
    }

    func testAnEmptyOrImpossibleRequestIsEmptyRatherThanACrash() {
        let source = bitmap(4, 4) { _, _ in (1, 2, 3, 255) }
        XCTAssertTrue(Raster.resampled(source, toSquare: 0).isEmpty)
        XCTAssertTrue(Raster.resampled(Raster.Bitmap(width: 0, height: 0), toSquare: 20).isEmpty)
    }

    func testTheResultIsAlwaysTheSizeAskedFor() {
        let source = bitmap(37, 23) { x, y in (UInt8(x * 3), UInt8(y * 5), 0, 255) }
        for size in [1, 2, 7, 20, 23, 37, 64, 255] {
            let out = Raster.resampled(source, toSquare: size)
            XCTAssertEqual(out.width, size)
            XCTAssertEqual(out.height, size)
            XCTAssertEqual(out.rgba.count, size * size * 4)
        }
    }

    // MARK: Through the whole path

    func testAPngShrinksToAnIconGridWithItsCornersIntact() throws {
        let data = PNG.corners(size: 100, block: 25)
        let image = try XCTUnwrap(Raster.decode(Array(data)))
        let icon = Raster.resampled(image, toSquare: 20)
        XCTAssertEqual(icon[1, 1].r, 255, "the red corner survived 5:1")
        XCTAssertEqual(icon[18, 18].b, 255, "so did the blue one")
        XCTAssertEqual(icon[10, 10].a, 0, "and the middle is still clear")
    }

    // MARK: A pair of axes going opposite ways

    /// A tall sliver onto a square grid: 25:1 down, 1.25:1 across. Bilinear would sample
    /// past the sparse opaque rows; the area average covers all of them.
    func testAnAxisThatShrinksIsAveragedEvenWhileTheOtherGrows() {
        var source = Raster.Bitmap(width: 16, height: 500)
        // One opaque red row in fifty, the rest transparent black.
        for y in stride(from: 0, to: 500, by: 50) {
            for x in 0..<16 {
                let i = (y * 16 + x) * 4
                source.rgba[i] = 255
                source.rgba[i + 3] = 255
            }
        }
        let out = Raster.resampled(source, toSquare: 20)
        XCTAssertEqual(out.width, 20)
        XCTAssertEqual(out.height, 20)

        // Ten opaque rows in five hundred is two per cent of the ink, so a mean alpha
        // near 5 must survive.
        let ink = out.rgba.enumerated().filter { $0.offset % 4 == 3 }
            .reduce(0) { $0 + Int($1.element) }
        let meanAlpha = Double(ink) / Double(20 * 20)
        XCTAssertGreaterThan(meanAlpha, 3,
                             "a 25:1 shrink that samples instead of averaging loses the ink")
        let rowsWithInk = (0..<20).filter { y in
            (0..<20).contains { x in out[x, y].a > 0 }
        }
        XCTAssertGreaterThanOrEqual(rowsWithInk.count, 10)
        // What survives is red, not a mean taken with the transparent black around it.
        for y in rowsWithInk {
            let pixel = out[10, y]
            XCTAssertGreaterThan(pixel.r, 200)
            XCTAssertLessThan(pixel.g, 40)
        }
    }

    /// When both axes shrink or both grow, the per-axis choice makes no difference.
    func testAgreeingAxesAreUntouchedByTheChange() {
        var source = Raster.Bitmap(width: 64, height: 64)
        for i in stride(from: 0, to: source.rgba.count, by: 4) {
            source.rgba[i] = UInt8((i / 4) % 256)
            source.rgba[i + 1] = UInt8((i / 4 / 64) % 256)
            source.rgba[i + 2] = 128
            source.rgba[i + 3] = 255
        }
        // Both shrinking, and both growing: one filter each, one pass each.
        XCTAssertEqual(Raster.resampled(source, toSquare: 20).rgba.count, 20 * 20 * 4)
        XCTAssertEqual(Raster.resampled(source, toSquare: 128).rgba.count, 128 * 128 * 4)
        // A square source on a square grid never reaches the mixed path at all.
        XCTAssertEqual(Raster.resampled(source, toSquare: 64), source)
    }
}
