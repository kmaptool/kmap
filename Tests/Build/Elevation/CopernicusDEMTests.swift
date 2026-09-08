import XCTest
@testable import kmap

/// Where a Copernicus tile is fetched from, and what it is called once it is here. A wrong
/// name is the quiet failure: the tile lands under a name nothing looks for, is fetched
/// again on every build, and the ground it covers stays flat.
final class CopernicusDEMTests: XCTestCase {

    func testTheCellNameIsTheSameRuleEveryOtherSourceUses() {
        for (lat, lon) in [(44, 33), (-34, -71), (0, 0), (50, -1), (-9, 116), (89, 179)] {
            XCTAssertEqual(CopernicusDEM.cellName(lat: lat, lon: lon),
                           HGTName.of(lat: lat, lon: lon))
        }
        XCTAssertEqual(CopernicusDEM.cellName(lat: 44, lon: 34), "N44E034")
    }

    func testTheBucketURLCarriesTheCornerInTheBucketsOwnSpelling() {
        XCTAssertEqual(CopernicusDEM.tileURL(lat: 44, lon: 34)?.absoluteString,
                       "https://copernicus-dem-30m.s3.amazonaws.com/"
                       + "Copernicus_DSM_COG_10_N44_00_E034_00_DEM/"
                       + "Copernicus_DSM_COG_10_N44_00_E034_00_DEM.tif")
    }

    func testTheURLIsRightBelowTheEquatorAndWestOfGreenwich() {
        let south = CopernicusDEM.tileURL(lat: -34, lon: -71)?.absoluteString ?? ""
        XCTAssertTrue(south.contains("Copernicus_DSM_COG_10_S34_00_W071_00_DEM"), south)
        let meridian = CopernicusDEM.tileURL(lat: 0, lon: 0)?.absoluteString ?? ""
        XCTAssertTrue(meridian.contains("Copernicus_DSM_COG_10_N00_00_E000_00_DEM"), meridian)
    }

    func testTheCachedTileSitsUnderTheSourcesOwnDirectoryWithAnHgtExtension() {
        // The DEM layer ranks sources by the digit in the directory name, so the label
        // is not a free choice.
        XCTAssertEqual(CopernicusDEM.directoryName, "COP1")
        let url = CopernicusDEM.cachedTile(lat: -34, lon: -71)
        XCTAssertEqual(url.lastPathComponent, "S34W071.hgt")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "COP1")
    }

    func testTheDownloadedTifLivesInTheCacheNotTheWorkArea() {
        // A rerun reads the tif cache to skip finished downloads, so it must sit outside
        // the per-build work directory that cleanup removes.
        let tif = CopernicusDEM.downloadedTif(lat: 44, lon: 34)
        XCTAssertEqual(tif.lastPathComponent, "N44E034.tif")
        XCTAssertTrue(tif.path.hasPrefix(Paths.cache.path),
                      "the tif cache must survive the build's own cleanup")
        XCTAssertFalse(tif.path.contains("/work/"),
                       "a work path is deleted with the build, and the resume with it")
        XCTAssertEqual(CopernicusDEM.tifCacheDirectory.lastPathComponent, "copernicus-tif")
    }

    func testTheClipPolygonIsAClosedRectangleInOsmosisOrder() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-clip-\(UUID().uuidString).poly")
        defer { try? FileManager.default.removeItem(at: url) }
        try CopernicusDEM.writeClipPolygon(
            BBox(minLon: 5.5, minLat: 49.5, maxLon: 6.5, maxLat: 50.5), to: url)
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.first, "kmap-clip")
        XCTAssertEqual(lines.filter { $0 == "END" }.count, 2)
        let points = lines.filter { $0.contains(" ") && $0 != "kmap-clip" }
        // Five points: four corners and the first again, or the ring is not closed and
        // pyhgtmap contours the whole degree.
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.first, points.last)
        XCTAssertTrue(points[0].hasPrefix("5.5 "), points[0])
        XCTAssertTrue(points[2].hasPrefix("6.5 "), points[2])
    }

    func testTheTwoResolutionsNeverShareAShelf() {
        // A 90 m tif under a 30 m name would convert wrongly, and a COP3 `.hgt` under
        // COP1 would win the finest-source ordering.
        let g30 = CopernicusDEM.glo30, g90 = CopernicusDEM.glo90
        XCTAssertNotEqual(g30.cacheDirectory, g90.cacheDirectory)
        XCTAssertNotEqual(g30.tifCacheDirectory, g90.tifCacheDirectory)
        XCTAssertEqual(g30.directoryName, "COP1")
        XCTAssertEqual(g90.directoryName, "COP3", "the 3 is load-bearing for source ranking")
        XCTAssertEqual(g30.nodes, 3601)
        XCTAssertEqual(g90.nodes, 1201)
    }

    func testTheNinetyMetreBucketAndNamingAreTheirOwn() throws {
        let url = try XCTUnwrap(CopernicusDEM.glo90.tileURL(lat: 62, lon: -7))
        XCTAssertEqual(url.absoluteString,
                       "https://copernicus-dem-90m.s3.amazonaws.com/"
                       + "Copernicus_DSM_COG_30_N62_00_W007_00_DEM/"
                       + "Copernicus_DSM_COG_30_N62_00_W007_00_DEM.tif")
        // And the 30 m spelling is untouched by the flavor split.
        let old = try XCTUnwrap(CopernicusDEM.tileURL(lat: 44, lon: 34))
        XCTAssertTrue(old.absoluteString.contains("copernicus-dem-30m"))
        XCTAssertTrue(old.absoluteString.contains("COG_10_N44_00_E034_00"))
    }

    func testAFlavorIsChosenByWholeIdNeverByPrefix() {
        // Ids are matched whole; a prefix match would select both flavors.
        let ids = ["copernicus3"]
        let matched = CopernicusDEM.flavors.filter { ids.contains($0.sourceID) }
        XCTAssertEqual(matched.map(\.directoryName), ["COP3"])
    }

    func testTheOldSpellingsResolveAndTheNewOnesPassThrough() {
        // Source ids written under earlier spellings keep their meaning.
        XCTAssertEqual(CopernicusDEM.canonicalSourceID("copernicus"), "copernicus1")
        XCTAssertEqual(CopernicusDEM.canonicalSourceID("copernicus90"), "copernicus3")
        XCTAssertEqual(CopernicusDEM.canonicalSourceID("view1"), "view1")
        XCTAssertEqual(CopernicusDEM.canonicalSourceList("Copernicus, view3"),
                       "copernicus1,view3")
    }

    func testTheTileListReadsItsCRLFLinesAndYieldsCellNames() {
        // The bucket's list comes with CRLF endings, and "\r\n" is one Swift character
        // that splitting on "\n" alone does not divide — the whole file once collapsed
        // into a single line and one cell.
        let text = "Copernicus_DSM_COG_10_N44_00_E034_00_DEM\r\n"
            + "Copernicus_DSM_COG_10_S09_00_W140_00_DEM\r\n"
            + "not-a-stem\r\n"
        let cells = CopernicusDEM.parseTileList(text)
        XCTAssertEqual(cells, ["N44E034", "S09W140"])
    }

}
