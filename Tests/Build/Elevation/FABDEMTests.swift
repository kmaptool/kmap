import XCTest

@testable import kmap

/// Where a FABDEM tile is fetched from and what the index says it holds. The mirror files
/// each tile under a 10 deg folder, so a wrong folder name reads as open sea everywhere.
final class FABDEMTests: XCTestCase {
    func testItKeepsItsOwnShelvesAndRanksAsOneArcSecond() {
        let fab = FABDEM.v12
        XCTAssertEqual(fab.directoryName, "FAB1", "the 1 is load-bearing for source ranking")
        XCTAssertEqual(fab.nodes, 3601)
        for other in CopernicusDEM.flavors {
            XCTAssertNotEqual(fab.cacheDirectory, other.cacheDirectory)
            XCTAssertNotEqual(fab.tifCacheDirectory, other.tifCacheDirectory)
            XCTAssertNotEqual(fab.tileListCache, other.tileListCache)
        }
        XCTAssertEqual(DEMSources.named("fabdem1")?.sourceID, "fabdem1")
    }

    func testATileIsFoundInTheTenDegreeFolderNamedByItsCorners() throws {
        let url = try XCTUnwrap(FABDEM.v12.tileURL(lat: 43, lon: 41))
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/buckets/links-ads/fabdem/resolve/tiles/"
                + "N40E040-N50E050_FABDEM_V1-2/N43E041_FABDEM_V1-2.tif"
        )
        // South and west round away from the equator and the meridian, and the last column
        // closes on W180, as the archive spells it.
        XCTAssertEqual(FABDEM.folder(lat: -5, lon: -65), "S10W070-N00W060")
        XCTAssertEqual(FABDEM.folder(lat: 0, lon: 0), "N00E000-N10E010")
        XCTAssertEqual(FABDEM.folder(lat: -55, lon: -69), "S60W070-S50W060")
        XCTAssertEqual(FABDEM.folder(lat: 71, lon: 178), "N70E170-N80W180")
        XCTAssertEqual(FABDEM.folder(lat: 65, lon: -180), "N60W180-N70W170")
    }

    func testTheIndexYieldsCellNamesAndSkipsItsPaddedSpelling() {
        // A feature of the real index: file_name pads latitude to 3 digits, the other
        // 2 fields carry the cell name.
        let text = """
            { "type": "Feature", "properties": { "tile_name": "N079W106", \
            "file_name": "N079W106_FABDEM_V1-2.tif", \
            "zipfile_name": "N70W110-N80W100_FABDEM_V1-2.zip", \
            "href": "https://example.org/tiles/N70W110-N80W100_FABDEM_V1-2/N79W106_FABDEM_V1-2.tif", \
            "file_name_corrected": "N79W106_FABDEM_V1-2.tif" } },
            { "properties": { "file_name_corrected": "S09W140_FABDEM_V1-2.tif" } }
            """
        XCTAssertEqual(FABDEM.v12.parseTileList(text), ["N79W106", "S09W140"])
    }
}
