import XCTest
@testable import kmap

/// The Garmin Custom POI file kmap writes.
///
/// The shape of the format is checked here; `GPIAgainstGPSBabelTests` checks it against
/// the program that used to write it, byte for byte, where that program is installed.
final class GPIFileTests: XCTestCase {

    private func point(_ lat: Double, _ lon: Double, _ name: String, _ note: String)
        -> GPIFile.Point {
        GPIFile.Point(lat: lat, lon: lon, name: Array(name.utf8),
                      description: Array(note.utf8))
    }

    private func made(_ points: [GPIFile.Point], icon: GPIFile.Icon? = nil,
                      codePage: Int = 1252) -> Data {
        GPIFile.data(points: points, category: Array("kmap".utf8), codePage: codePage,
                     fileName: "my.gpi", icon: icon,
                     madeAt: GPIFile.epoch.addingTimeInterval(1_157_395_458))
    }

    func testItStartsWithTheFormatMarkerAndEndsWithTheClosingTag() {
        let data = made([point(45, 34, "AB", "CD")])
        XCTAssertEqual(data.prefix(8), Data([0, 0, 0, 0, 0x16, 0, 0, 0]))
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "GRMREC00")
        XCTAssertEqual(data.suffix(8), Data([0xff, 0xff, 0, 0, 0, 0, 0, 0]))
    }

    func testTheCodePageIsWrittenWhereTheDeviceLooksForIt() throws {
        // Written, not patched in afterwards: the text is encoded in this page.
        for page in [1250, 1251, 1252] {
            let data = made([point(45, 34, "AB", "CD")], codePage: page)
            let marker = Data("POI".utf8) + Data([0, 0, 0]) + Data("00".utf8)
            let at = try XCTUnwrap(data.firstRange(of: marker)?.upperBound)
            XCTAssertEqual(Int(data[at]) | Int(data[at + 1]) << 8, page)
        }
    }

    func testDegreesBecomeTheUnitGarminStoresThemIn() {
        // A full turn is 2^32 of them, so half a turn is 2^31.
        XCTAssertEqual(GPIFile.semicircles(45), 0x2000_0000)
        XCTAssertEqual(GPIFile.semicircles(-45), -0x2000_0000)
        XCTAssertEqual(GPIFile.semicircles(0), 0)
        // Rounded, not truncated: 46° lands a unit above the truncation.
        XCTAssertEqual(GPIFile.semicircles(46), 548_801_377)
        XCTAssertEqual(GPIFile.semicircles(34), 405_635_800)
    }

    func testAPointWithNoDescriptionCarriesItsNameInstead() {
        // A device shows something either way; an empty note would draw a blank card.
        let data = made([GPIFile.Point(lat: 45, lon: 34, name: Array("AB".utf8),
                                       description: [])])
        XCTAssertEqual(data.ranges(of: Data("AB".utf8)).count, 2)
    }

    func testTheIconIsLeftOutWhenThePointsAreNotDrawnOnTheMap() {
        let plain = made([point(45, 34, "AB", "CD")])
        let drawn = made([point(45, 34, "AB", "CD")], icon: .dot)
        XCTAssertLessThan(plain.count, drawn.count)
        // The bitmap is a record of its own; without it there is none.
        XCTAssertGreaterThan(drawn.count - plain.count, 24 * 24)
    }

    func testTheDrawnIconIsADiscWithARingAndNothingAroundIt() {
        let icon = GPIFile.Icon.dot
        XCTAssertEqual(icon.pixels.count, icon.width * icon.height)
        // The corners are the colour the device draws nothing for.
        XCTAssertEqual(icon.pixels[0], 0)
        XCTAssertEqual(icon.pixels[icon.width - 1], 0)
        // The middle is the fill, and the edge of the disc is the ring.
        XCTAssertEqual(icon.pixels[icon.height / 2 * icon.width + icon.width / 2], 1)
        XCTAssertTrue(icon.pixels.contains(2), "a ring is drawn")
    }
}
