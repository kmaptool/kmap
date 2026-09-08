import XCTest
@testable import kmap

/// Working out what a map's elevation will cost to fetch. Only the arithmetic is
/// exercised; the measurement itself needs HEAD requests to a public bucket.
final class ElevationCostTests: XCTestCase {

    private func region(_ id: String, _ boxes: [BBox]) -> Region {
        Region(id: id, name: id, parentID: nil, pbfURL: nil,
               bbox: boxes[0], boxes: boxes)
    }

    func testCellsAreTheDegreesTheRegionsActuallyCover() {
        let one = region("a", [BBox(minLon: 33.2, minLat: 44.3, maxLon: 34.8, maxLat: 45.4)])
        let cells = ElevationFootprint.boxCells(of: [one])
        // 33°–35° by 44°–46°: two columns of two.
        XCTAssertEqual(cells.count, 4)
        XCTAssertTrue(cells.contains { $0.lat == 44 && $0.lon == 33 })
        XCTAssertTrue(cells.contains { $0.lat == 45 && $0.lon == 34 })
    }

    /// A degree cell covered by two regions is fetched once and counted once.
    func testACellSharedByTwoRegionsIsCountedOnce() {
        let west = region("w", [BBox(minLon: 33.2, minLat: 44.3, maxLon: 34.5, maxLat: 44.8)])
        let east = region("e", [BBox(minLon: 34.2, minLat: 44.3, maxLon: 35.5, maxLat: 44.8)])
        let together = ElevationFootprint.boxCells(of: [west, east])
        XCTAssertEqual(together.count, 3, "33, 34 and 35 — the 34 in the middle only once")
    }

    /// A region is a set of boxes rather than the box around them, which may enclose
    /// ground the region does not cover.
    func testTheBoxesAreUsedRatherThanTheBoxAroundThem() {
        let split = region("s", [BBox(minLon: 30.0, minLat: 44.0, maxLon: 31.0, maxLat: 45.0),
                                 BBox(minLon: 40.0, minLat: 44.0, maxLon: 41.0, maxLat: 45.0)])
        XCTAssertEqual(ElevationFootprint.boxCells(of: [split]).count, 2)
        // The box around both would be eleven degrees wide.
        XCTAssertEqual(split.bbox.demTileCount, 1)
    }

    func testNoRegionsCostNothing() async {
        let estimate = await ElevationCost.estimate(sources: "copernicus1", regions: [])
        XCTAssertTrue(estimate.isEmpty)
    }
}

/// The chained estimate, with the network replaced: each source is costed over what the
/// ones listed before it leave behind, coverage comes from the sources' own lists, and
/// a small fetch has every file asked its size.
final class ElevationCostChainTests: XCTestCase {

    private var probe: ((URL) async throws -> Int64)!
    private var coverage: ((CopernicusDEM.Flavor) async -> Set<String>?)!
    private var viewIndex: ((Int) async -> ViewfinderDEM.Index?)!

    override func setUp() {
        super.setUp()
        probe = ElevationCost.probeSize
        coverage = ElevationCost.copernicusCoverage
        viewIndex = ElevationCost.viewfinderIndex
    }

    override func tearDown() {
        ElevationCost.probeSize = probe
        ElevationCost.copernicusCoverage = coverage
        ElevationCost.viewfinderIndex = viewIndex
        super.tearDown()
    }

    /// Mid-Pacific cells, so no developer's real cache can hold them.
    private let cells: [(lat: Int, lon: Int)] = [
        (-9, -140), (-9, -139), (-10, -140), (-10, -139),
    ]

    func testLaterSourcesPayOnlyForTheGapsEarlierOnesLeave() async {
        // GLO-30 publishes two of the four cells, GLO-90 three; one is open sea for both.
        ElevationCost.copernicusCoverage = { flavor in
            flavor.sourceID == "copernicus1"
                ? ["S09W140", "S09W139"]
                : ["S09W140", "S09W139", "S10W140"]
        }
        ElevationCost.probeSize = { _ in 10 }

        let out = await ElevationCost.estimate(sources: "copernicus1,copernicus3",
                                               cells: cells)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].published, 2, "GLO-30 fetches the two cells it publishes")
        XCTAssertEqual(out[0].bytes, 20)
        XCTAssertTrue(out[0].exact, "four files is a size asked of each, not sampled")
        XCTAssertEqual(out[1].published, 1, "GLO-90 pays only for the gap")
        XCTAssertEqual(out[1].bytes, 10)
        XCTAssertEqual(out[1].wanted, 2, "the sea cell is still wanted, just unpublished")
    }

    func testACellNoSourcePublishesCostsNothing() async {
        ElevationCost.copernicusCoverage = { _ in [] }
        ElevationCost.probeSize = { _ in XCTFail("nothing should be probed"); return 1 }
        let out = await ElevationCost.estimate(sources: "copernicus1", cells: cells)
        XCTAssertEqual(out.first?.bytes, 0)
        XCTAssertEqual(out.first?.published, 0)
        XCTAssertNotNil(out.first?.note)
    }

    func testALargeFetchIsSampledAsMeanTimesCount() async {
        // A hundred cells, far past the ask-them-all limit.
        var many: [(lat: Int, lon: Int)] = []
        for lon in 0..<100 { many.append((-80, lon - 170)) }
        ElevationCost.copernicusCoverage = { _ in
            Set(many.map { CopernicusDEM.cellName(lat: $0.lat, lon: $0.lon) })
        }
        // Counted under a lock: the probes run six lanes at once.
        let probes = Counter()
        ElevationCost.probeSize = { _ in probes.increment(); return 30 }
        let out = await ElevationCost.estimate(sources: "copernicus1", cells: many)
        XCTAssertEqual(out.first?.bytes, 3000, "mean of the sample times every cell")
        XCTAssertEqual(out.first?.exact, false)
        XCTAssertEqual(probes.value, ElevationCost.sampleSize)
        XCTAssertEqual(out.first?.sampled, ElevationCost.sampleSize)
    }

    func testTheCoverageListFailingFallsBackToBlindSampling() async {
        ElevationCost.copernicusCoverage = { _ in nil }
        ElevationCost.probeSize = { _ in 25 }
        let out = await ElevationCost.estimate(sources: "copernicus1", cells: cells)
        XCTAssertEqual(out.first?.bytes, 100, "mean times all four, sea unknowable")
        XCTAssertEqual(out.first?.exact, false)
        XCTAssertNotNil(out.first?.note)
    }

    func testViewfinderCountsEachZoneArchiveOnce() async {
        // One archive claims three of the cells; the fourth is unpublished.
        ElevationCost.viewfinderIndex = { _ in
            var index = ViewfinderDEM.Index()
            index.entries = ["https://example.org/DEM/zone.zip":
                                ["S09W140", "S09W139", "S10W140"]]
            return index
        }
        ElevationCost.probeSize = { _ in 500 }
        let out = await ElevationCost.estimate(sources: "view1", cells: cells)
        XCTAssertEqual(out.first?.archives, 1)
        XCTAssertEqual(out.first?.bytes, 500, "one archive, however many cells it holds")
        XCTAssertEqual(out.first?.published, 3)
    }

    func testViewfinderAfterCopernicusPaysOnlyForWhatIsLeft() async {
        ElevationCost.copernicusCoverage = { _ in ["S09W140", "S09W139"] }
        ElevationCost.viewfinderIndex = { _ in
            var index = ViewfinderDEM.Index()
            index.entries = ["https://example.org/DEM/zone.zip":
                                ["S09W140", "S09W139", "S10W140"]]
            return index
        }
        ElevationCost.probeSize = { _ in 500 }
        let out = await ElevationCost.estimate(sources: "copernicus1,view1", cells: cells)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].published, 1, "only the cell Copernicus does not publish")
        XCTAssertEqual(out[1].archives, 1)
    }

    func testACredentialedSourceReportsWhatIsLeftWithANote() async {
        ElevationCost.copernicusCoverage = { _ in ["S09W140"] }
        ElevationCost.probeSize = { _ in 10 }
        let out = await ElevationCost.estimate(sources: "copernicus1,srtm1", cells: cells)
        XCTAssertEqual(out[1].wanted, 3, "the three cells GLO-30 does not settle")
        XCTAssertNil(out[1].bytes)
        XCTAssertNotNil(out[1].note)
    }
}
