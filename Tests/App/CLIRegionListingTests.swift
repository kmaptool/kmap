import XCTest
@testable import kmap

/// What `kmap regions` lists for a query: the continents, the inside of a region named
/// by its exact id, or a search.
final class CLIRegionListingTests: XCTestCase {
    private func feature(id: String, name: String, parent: String? = nil) -> [String: Any] {
        var properties: [String: Any] = ["id": id, "name": name,
                                         "urls": ["pbf": "https://x/\(id).osm.pbf"]]
        if let parent { properties["parent"] = parent }
        return ["properties": properties]
    }

    private func index() throws -> RegionIndex {
        let data = try JSONSerialization.data(withJSONObject: ["features": [
            feature(id: "europe", name: "Europe"),
            feature(id: "asia", name: "Asia"),
            feature(id: "austria", name: "Austria", parent: "europe"),
            feature(id: "germany", name: "Germany", parent: "europe"),
            feature(id: "bayern", name: "Bayern", parent: "germany"),
            feature(id: "dach", name: "Germany, Austria, Switzerland", parent: "europe"),
        ]])
        let index = RegionIndex()
        try index.parse(data)
        return index
    }

    func testNoQueryListsTheContinents() throws {
        let (listing, regions) = CLI.regionListing(for: "  ", in: try index())
        guard case .roots = listing else { return XCTFail("expected the roots") }
        XCTAssertEqual(regions.map(\.id), ["asia", "europe"])
    }

    func testAnExactIdWithSubRegionsOpensItAndListsThem() throws {
        let (listing, regions) = CLI.regionListing(for: "Europe", in: try index())
        guard case .opened(let region) = listing else { return XCTFail("expected Europe opened") }
        XCTAssertEqual(region.id, "europe")
        XCTAssertEqual(regions.map(\.id), ["austria", "germany", "dach"])
    }

    func testOpeningGoesOneLevelDownAtATime() throws {
        let (_, regions) = CLI.regionListing(for: "germany", in: try index())
        XCTAssertEqual(regions.map(\.id), ["bayern"])
    }

    func testALeafsIdSearchesSoTheLeafItselfIsFound() throws {
        let (listing, regions) = CLI.regionListing(for: "austria", in: try index())
        guard case .search = listing else { return XCTFail("expected a search") }
        XCTAssertEqual(regions.first?.id, "austria")
        XCTAssertTrue(regions.map(\.id).contains("dach"))
    }

    func testAnythingElseSearches() throws {
        let (listing, regions) = CLI.regionListing(for: "bay", in: try index())
        guard case .search = listing else { return XCTFail("expected a search") }
        XCTAssertEqual(regions.map(\.id), ["bayern"])
    }
}
