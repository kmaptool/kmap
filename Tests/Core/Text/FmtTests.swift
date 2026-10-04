import XCTest

@testable import kmap

/// The numbers a reader sees.
final class FmtTests: XCTestCase {
    func testBytesUseTheDecimalUnitsDownloadSitesQuote() {
        XCTAssertEqual(Fmt.bytes(0), "0 B")
        XCTAssertEqual(Fmt.bytes(999), "999 B")
        XCTAssertEqual(Fmt.bytes(1_000), "1 kB")
        XCTAssertEqual(Fmt.bytes(999_999), "1000 kB")
        XCTAssertEqual(Fmt.bytes(1_000_000), "1.0 MB")
        XCTAssertEqual(Fmt.bytes(41_900_000), "41.9 MB")
        XCTAssertEqual(Fmt.bytes(1_000_000_000), "1.00 GB")
        XCTAssertEqual(Fmt.bytes(6_680_000_000), "6.68 GB")
    }

    func testDurationsReadTheWayAPersonSaysThem() {
        XCTAssertEqual(Fmt.duration(0), "0s")
        XCTAssertEqual(Fmt.duration(48), "48s")
        XCTAssertEqual(Fmt.duration(59.4), "59s")
        // Rounded first, then split: 59.6 s is a minute, not "60s".
        XCTAssertEqual(Fmt.duration(59.6), "1m 00s")
        XCTAssertEqual(Fmt.duration(60), "1m 00s")
        XCTAssertEqual(Fmt.duration(252), "4m 12s")
        XCTAssertEqual(Fmt.duration(3_600), "1h 00m")
        XCTAssertEqual(Fmt.duration(3_780), "1h 03m")
    }

    func testNonsenseTimesAndRatesShowADashRatherThanANumber() {
        // A rate is computed by dividing by an elapsed time that can be zero on the first
        // tick, and a remaining time by dividing by a rate that can be zero.
        XCTAssertEqual(Fmt.duration(.nan), "—")
        XCTAssertEqual(Fmt.duration(.infinity), "—")
        XCTAssertEqual(Fmt.duration(-1), "—")
        XCTAssertEqual(Fmt.duration(60 * 60 * 48), "—")
        XCTAssertEqual(Fmt.rate(0), "—")
        XCTAssertEqual(Fmt.rate(-5), "—")
        XCTAssertEqual(Fmt.rate(.nan), "—")
        XCTAssertEqual(Fmt.rate(2_500_000), "2.5 MB/s")
    }

    func testPercentIsClampedAndNeverShowsNaN() {
        XCTAssertEqual(Fmt.percent(0), "  0%")
        XCTAssertEqual(Fmt.percent(0.5), " 50%")
        XCTAssertEqual(Fmt.percent(1), "100%")
        XCTAssertEqual(Fmt.percent(1.4), "100%")
        XCTAssertEqual(Fmt.percent(-3), "  0%")
        XCTAssertEqual(Fmt.percent(.nan), "  0%")
    }

    func testCoordinatesCarryTheCompassPointRatherThanASign() {
        XCTAssertEqual(Fmt.coord(44.5, lat: true), "44.50°N")
        XCTAssertEqual(Fmt.coord(-33.87, lat: true), "33.87°S")
        XCTAssertEqual(Fmt.coord(34.1, lat: false), "34.10°E")
        XCTAssertEqual(Fmt.coord(-71.2, lat: false), "71.20°W")
        // Zero belongs to the northern and eastern side, as every tile name has it.
        XCTAssertEqual(Fmt.coord(0, lat: true), "0.00°N")
        XCTAssertEqual(Fmt.coord(0, lat: false), "0.00°E")
    }
}
