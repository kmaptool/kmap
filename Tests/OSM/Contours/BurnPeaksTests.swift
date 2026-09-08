import XCTest
@testable import kmap

/// Burning OSM summit heights into the .hgt tiles a build is about to contour.
///
/// A cell straddling a cliff averages the top of the face with the bottom, so a cliff-top
/// summit reads low; raising that one cell to the tagged height corrects it, within limits.
final class BurnPeaksTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")
    private let side = 3601

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-peaks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Names

    func testATileIsNamedForItsSouthWestCornerInEitherHemisphere() {
        XCTAssertEqual(HGTName.of(lat: 44, lon: 33), "N44E033")
        XCTAssertEqual(HGTName.of(lat: -34, lon: -71), "S34W071")
        XCTAssertEqual(HGTName.of(lat: 0, lon: 0), "N00E000")
        // A coordinate belongs to the tile whose corner is below and left of it.
        XCTAssertEqual(HGTName.of(lat: 44.6, lon: 33.2), "N44E033")
        XCTAssertEqual(HGTName.of(lat: -33.4, lon: -70.6), "S34W071")
    }

    func testANameReadsBackAsTheCornerItStandsFor() {
        for (lat, lon) in [(44, 33), (-34, -71), (0, 0), (-1, -1), (82, 179)] {
            let corner = HGTName.corner(of: HGTName.of(lat: lat, lon: lon) + ".hgt")
            XCTAssertEqual(corner?.lat, lat, "\(lat),\(lon)")
            XCTAssertEqual(corner?.lon, lon, "\(lat),\(lon)")
        }
    }

    func testSomethingThatIsNotATileNameIsNotOne() {
        XCTAssertNil(HGTName.corner(of: "contour0001.osm.pbf"))
        XCTAssertNil(HGTName.corner(of: "N44.hgt"))
        XCTAssertNil(HGTName.corner(of: "X44E033.hgt"))
        XCTAssertNil(HGTName.corner(of: ""))
    }

    // MARK: Reading `ele`

    func testAHeightIsTakenHoweverOSMSpellsIt() {
        XCTAssertEqual(BurnPeaks.metres("1527"), 1527)
        XCTAssertEqual(BurnPeaks.metres("1527.4"), 1527.4)
        XCTAssertEqual(BurnPeaks.metres("1527 m"), 1527)
        XCTAssertEqual(BurnPeaks.metres("1527m"), 1527)
        XCTAssertEqual(BurnPeaks.metres("1 527"), 1527)
        XCTAssertEqual(BurnPeaks.metres("1527 metres"), 1527)
        XCTAssertEqual(BurnPeaks.metres("1527,4"), 1527.4)
    }

    func testAHeightInFeetIsRefusedRatherThanConverted() {
        // Converting would turn a mistagged unit into a plausible wrong height.
        XCTAssertNil(BurnPeaks.metres("5000 ft"))
        XCTAssertNil(BurnPeaks.metres("5000'"))
        XCTAssertNil(BurnPeaks.metres("5000 feet"))
    }

    func testNonsenseIsNoHeight() {
        XCTAssertNil(BurnPeaks.metres(nil))
        XCTAssertNil(BurnPeaks.metres(""))
        XCTAssertNil(BurnPeaks.metres("   "))
        XCTAssertNil(BurnPeaks.metres("high"))
        XCTAssertNil(BurnPeaks.metres("99999"))       // above any real summit
        XCTAssertNil(BurnPeaks.metres("-9999"))
    }

    func testGroundBelowSeaLevelIsAHeightLikeAnyOther() {
        XCTAssertEqual(BurnPeaks.metres("-430"), -430)   // dry ground below sea level
    }

    // MARK: Burning

    /// A tile of flat ground at one height.
    private func tile(_ name: String, height: Int16 = 1000) throws -> URL {
        try HGTFixture.constant(height, at: directory.appendingPathComponent(name))
    }

    private func extract(_ peaks: [(lat: Double, lon: Double, ele: String, name: String)])
        throws -> URL {
        let url = directory.appendingPathComponent("peaks.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes(peaks.enumerated().map { index, peak in
            PBFWriter.Node(id: Int64(index + 1), lat: peak.lat, lon: peak.lon,
                           tags: [("natural", "peak"), ("ele", peak.ele),
                                  ("name", peak.name)])
        })
        try writer.finish()
        return url
    }

    private func burn(_ peaks: [(lat: Double, lon: Double, ele: String, name: String)],
                      tileName: String, height: Int16 = 1000) throws -> BurnPeaks.Report {
        let hgt = directory.appendingPathComponent("hgt")
        try FileManager.default.createDirectory(at: hgt, withIntermediateDirectories: true)
        try HGTFixture.constant(height, at: hgt.appendingPathComponent(tileName))
        return try BurnPeaks(pbf: try extract(peaks), hgt: hgt,
                             out: directory.appendingPathComponent("out")).run()
    }

    func testASummitAboveItsCellIsRaisedToWhatOSMSays() throws {
        let report = try burn([(44.5, 33.5, "1040", "Peak")], tileName: "N44E033.hgt")
        XCTAssertEqual(report.peaks, 1)
        XCTAssertEqual(report.raised, 1)
        XCTAssertEqual(report.gains, [40])
        XCTAssertEqual(report.written, ["N44E033.hgt"])
    }

    func testASummitInTheSouthernAndWesternHemispheresIsFoundToo() throws {
        let report = try burn([(-33.4, -70.6, "1040", "Peak")], tileName: "S34W071.hgt")
        XCTAssertEqual(report.raised, 1, "the southern hemisphere was not found")
        XCTAssertEqual(report.outside, 0)
    }

    func testASummitLowerThanItsCellIsLeftAlone() throws {
        // Lowering the cell would dig a pit at the summit.
        let report = try burn([(44.5, 33.5, "980", "Peak")], tileName: "N44E033.hgt")
        XCTAssertEqual(report.already, 1)
        XCTAssertEqual(report.raised, 0)
        XCTAssertTrue(report.written.isEmpty)
    }

    func testASummitThatDisagreesWithTheTerrainIsRefused() throws {
        // A gain past the tolerance reads as a mistagged height, not as a correction.
        let report = try burn([(44.5, 33.5, "1200", "Wrong")], tileName: "N44E033.hgt")
        XCTAssertEqual(report.raised, 0)
        XCTAssertEqual(report.rejected.count, 1)
        XCTAssertEqual(report.rejected.first?.why, "disagrees with the terrain")
    }

    func testASummitOnATileTheBuildDoesNotHaveIsCounted() throws {
        let report = try burn([(10.5, 20.5, "1040", "Elsewhere")], tileName: "N44E033.hgt")
        XCTAssertEqual(report.outside, 1)
        XCTAssertEqual(report.raised, 0)
    }

    func testANodeThatIsNotASummitIsIgnored() throws {
        let hgt = directory.appendingPathComponent("hgt")
        try FileManager.default.createDirectory(at: hgt, withIntermediateDirectories: true)
        _ = try tile("N44E033.hgt")
        try FileManager.default.moveItem(at: directory.appendingPathComponent("N44E033.hgt"),
                                         to: hgt.appendingPathComponent("N44E033.hgt"))
        let url = directory.appendingPathComponent("other.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes([PBFWriter.Node(id: 1, lat: 44.5, lon: 33.5,
                                     tags: [("natural", "tree"), ("ele", "1040")])])
        try writer.finish()
        let report = try BurnPeaks(pbf: url, hgt: hgt,
                                   out: directory.appendingPathComponent("out")).run()
        XCTAssertEqual(report.peaks, 0)
    }

    func testAVolcanoCountsAsASummit() throws {
        let hgt = directory.appendingPathComponent("hgt")
        try FileManager.default.createDirectory(at: hgt, withIntermediateDirectories: true)
        _ = try tile("N44E033.hgt")
        try FileManager.default.moveItem(at: directory.appendingPathComponent("N44E033.hgt"),
                                         to: hgt.appendingPathComponent("N44E033.hgt"))
        let url = directory.appendingPathComponent("volcano.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes([PBFWriter.Node(id: 1, lat: 44.5, lon: 33.5,
                                     tags: [("natural", "volcano"), ("ele", "1040")])])
        try writer.finish()
        let report = try BurnPeaks(pbf: url, hgt: hgt,
                                   out: directory.appendingPathComponent("out")).run()
        XCTAssertEqual(report.peaks, 1)
        XCTAssertEqual(report.raised, 1)
    }

    func testHalfAMetreRoundsUpwards() throws {
        // Half a metre rounds up, not to the nearest even number.
        let report = try burn([(44.5, 33.5, "1040.5", "Peak")], tileName: "N44E033.hgt")
        XCTAssertEqual(report.gains, [41])
    }
}
