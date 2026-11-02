import XCTest

@testable import kmap

final class ElevationFetchTests: XCTestCase {
    func testAPyhgtmapLineNamesItsCell() {
        XCTAssertEqual(BuildPipeline.pyhgtmapCell("N45E034: trying srtm1 ..."), "N45E034")
        XCTAssertEqual(BuildPipeline.pyhgtmapCell("S05W120: trying alos1 ..."), "S05W120")
        XCTAssertNil(BuildPipeline.pyhgtmapCell("N45E034: no file found on server."))
        XCTAssertNil(BuildPipeline.pyhgtmapCell("Downloading N45E034: trying"))
    }

    /// Cached cells are not counted.
    func testPyhgtmapCountsTheFetchedCellsItIsPast() {
        let fetching: Set = ["N45E034", "N45E036"]
        XCTAssertEqual(BuildPipeline.pyhgtmapFetched([], of: fetching), 0)
        XCTAssertEqual(BuildPipeline.pyhgtmapFetched(["N45E034"], of: fetching), 0)
        XCTAssertEqual(BuildPipeline.pyhgtmapFetched(["N45E034", "N45E035"], of: fetching), 1)
        XCTAssertEqual(BuildPipeline.pyhgtmapFetched(["N45E034", "N45E035", "N45E036"], of: fetching), 1)
    }

    /// Mid-Pacific, so no real cache holds it.
    private let sea = "S10W140"

    func testViewfinderFetchesWhereAnArchiveIsFirstToOffer() {
        XCTAssertTrue(BuildPipeline.viewfinderFetches(sea, resolutions: [1, 3]) { $0 == 3 })
        XCTAssertFalse(BuildPipeline.viewfinderFetches(sea, resolutions: [1, 3]) { _ in false })
        XCTAssertFalse(BuildPipeline.viewfinderFetches(sea, resolutions: []) { _ in true })
    }

    func testPyhgtmapFetchesWhatItsFirstSourceLacks() throws {
        let directory = BuildPipeline.pyhgtmapDirectory("srtm1")
        let held = directory.appendingPathComponent("S10W139.tif")
        Paths.ensure(directory)
        try FileTools.write(Data(), to: held)
        defer { FileTools.removeIfPresent(held) }
        XCTAssertEqual(
            BuildPipeline.pyhgtmapFetching([(-10, -140), (-10, -139)], first: "srtm1"),
            [sea]
        )
    }
}
