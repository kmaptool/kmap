import XCTest
@testable import kmap

/// Reading the identifying header of a Garmin style file.
///
/// The family and product ids in a TYP must match the ones mkgmap is invoked with, or the
/// receiver ignores the TYP and draws the map in its default colours.
final class TypFileTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-typ-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A binary TYP: the header length, "GARMIN TYP", and the ids at their fixed offsets.
    private func binary(family: Int, product: Int, name: String = "style.typ",
                        signed: Bool = true) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        bytes[0] = 0x5B; bytes[1] = 0x00
        if signed {
            for (i, byte) in TypInfo.signature.enumerated() { bytes[2 + i] = byte }
        }
        bytes[0x2F] = UInt8(family & 0xFF); bytes[0x30] = UInt8((family >> 8) & 0xFF)
        bytes[0x31] = UInt8(product & 0xFF); bytes[0x32] = UInt8((product >> 8) & 0xFF)
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func text(_ body: String, name: String = "style.txt") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Binary

    func testABinaryStyleGivesUpItsFamilyAndProduct() throws {
        let info = try XCTUnwrap(TypInfo.read(try binary(family: 6324, product: 2)))
        XCTAssertEqual(info.familyID, 6324)
        XCTAssertEqual(info.productID, 2)
        XCTAssertTrue(info.isBinary)
    }

    func testAFamilyPastTwoHundredAndFiftySixIsReadFromBothItsBytes() throws {
        // 6324 does not fit in one byte; the low byte alone reads as a plausible 180.
        let info = try XCTUnwrap(TypInfo.read(try binary(family: 6324, product: 1)))
        XCTAssertEqual(info.familyID, 6324)
        XCTAssertEqual(try XCTUnwrap(TypInfo.read(try binary(family: 65_535, product: 1)))
                        .familyID, 65_535)
    }

    func testAProductOfZeroIsReadAsOneBecauseTheDeviceCountsFromThere() throws {
        XCTAssertEqual(TypInfo.read(try binary(family: 6324, product: 0))?.productID, 1)
    }

    func testSomethingWithoutTheGarminMarkIsNotAStyle() throws {
        // The extension is only a claim.
        XCTAssertNil(TypInfo.read(try binary(family: 6324, product: 1, signed: false)))
    }

    func testAStyleWithNoFamilyIsRefused() throws {
        // Family zero would collide with every map on the receiver.
        XCTAssertNil(TypInfo.read(try binary(family: 0, product: 1)))
    }

    func testAFileTooShortToHoldTheIdsIsRefused() throws {
        let url = directory.appendingPathComponent("short.typ")
        try Data([0x5B, 0x00] + TypInfo.signature).write(to: url)
        XCTAssertNil(TypInfo.read(url))
        XCTAssertNil(TypInfo.read(directory.appendingPathComponent("absent.typ")))
    }

    // MARK: mkgmap's own TYP source

    func testATextStyleIsReadFromItsFIDAndProductCode() throws {
        let info = try XCTUnwrap(TypInfo.read(try text("""
        [_id]
        ProductCode=3
        FID=6324
        CodePage=1251
        [end]
        """)))
        XCTAssertEqual(info.familyID, 6324)
        XCTAssertEqual(info.productID, 3)
        XCTAssertFalse(info.isBinary)
    }

    func testTheKeysAreReadWhateverTheirCaseAndSpacing() throws {
        let info = try XCTUnwrap(TypInfo.read(try text("  fid  =  6324  \nproductcode=2\n")))
        XCTAssertEqual(info.familyID, 6324)
        XCTAssertEqual(info.productID, 2)
    }

    func testACommentAfterTheValueIsNotPartOfIt() throws {
        let info = try XCTUnwrap(TypInfo.read(try text("FID=6324 ; the family\nProductCode=1\n")))
        XCTAssertEqual(info.familyID, 6324)
    }

    func testATextStyleWithoutAFamilyIsRefused() throws {
        XCTAssertNil(TypInfo.read(try text("[_id]\nProductCode=1\nCodePage=1252\n[end]")))
        XCTAssertNil(TypInfo.read(try text("nothing that looks like a style at all")))
    }

    func testAMissingProductCodeMeansTheFirstProduct() throws {
        XCTAssertEqual(TypInfo.read(try text("FID=6324\n"))?.productID, 1)
        // And so does one that is not a number.
        XCTAssertEqual(TypInfo.read(try text("FID=6324\nProductCode=abc\n"))?.productID, 1)
    }

    func testTheFileIsChosenByItsExtensionNotByGuessing() throws {
        // Reading a text file as binary, or the reverse, yields a family id out of noise.
        let asText = try text("FID=6324\n", name: "style.txt")
        XCTAssertEqual(TypInfo.read(asText)?.isBinary, false)
        let asBinary = try binary(family: 6324, product: 1, name: "style.typ")
        XCTAssertEqual(TypInfo.read(asBinary)?.isBinary, true)
    }
}
