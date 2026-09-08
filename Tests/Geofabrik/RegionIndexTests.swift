import XCTest
@testable import kmap

/// Parsing Geofabrik's region index: the coverage a region reports, the parent links
/// between extracts, the download URLs and the search ranking.
final class RegionIndexTests: XCTestCase {

    private func feature(id: String, name: String, parent: String? = nil,
                         pbf: String? = nil, geometry: Any? = nil) -> [String: Any] {
        var properties: [String: Any] = ["id": id, "name": name]
        if let parent { properties["parent"] = parent }
        if let pbf { properties["urls"] = ["pbf": pbf] }
        var out: [String: Any] = ["properties": properties]
        if let geometry {
            out["geometry"] = ["type": "Polygon", "coordinates": geometry]
        }
        return out
    }

    /// A GeoJSON ring: an array of [lon, lat] pairs.
    private func ring(_ points: [(Double, Double)]) -> [[Double]] {
        points.map { [$0.0, $0.1] }
    }

    private func index(_ features: [[String: Any]]) throws -> RegionIndex {
        let data = try JSONSerialization.data(withJSONObject: ["features": features])
        let index = RegionIndex()
        try index.parse(data)
        return index
    }

    private func box(_ minLon: Double, _ minLat: Double,
                     _ maxLon: Double, _ maxLat: Double) -> BBox {
        BBox(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat)
    }

    // MARK: The shape of a region

    func testAPolygonBecomesOneBoxAroundIt() throws {
        let smallRegion = feature(id: "continent/small-region", name: "Small Region",
                                  parent: "continent",
                                  pbf: "https://download.geofabrik.de/continent/small-region-latest.osm.pbf",
                                  geometry: [ring([(5.7, 49.4), (6.5, 49.4), (6.5, 50.2),
                                                   (5.7, 50.2), (5.7, 49.4)])])
        let parsed = try index([feature(id: "continent", name: "Continent"), smallRegion])
        let region = try XCTUnwrap(parsed.region("continent/small-region"))
        XCTAssertEqual(region.boxes.count, 1)
        XCTAssertEqual(region.bbox, box(5.7, 49.4, 6.5, 50.2))
        XCTAssertEqual(region.demTileCount, 1 * 1 * 0 + box(5.7, 49.4, 6.5, 50.2).demTileCount)
    }

    func testAMultiPolygonKeepsABoxPerRing() throws {
        // MultiPolygon nests its rings one level deeper than Polygon does.
        let multi: [String: Any] = [
            "properties": ["id": "x/islands", "name": "Islands"],
            "geometry": ["type": "MultiPolygon",
                         "coordinates": [[ring([(0, 0), (1, 0), (1, 1), (0, 1), (0, 0)])],
                                         [ring([(10, 10), (11, 10), (11, 11), (10, 11), (10, 10)])]]]
        ]
        let region = try XCTUnwrap(try index([multi]).region("x/islands"))
        XCTAssertEqual(region.boxes.count, 2)
        XCTAssertTrue(region.boxes.contains(box(0, 0, 1, 1)))
        XCTAssertTrue(region.boxes.contains(box(10, 10, 11, 11)))
        XCTAssertEqual(region.bbox, box(0, 0, 11, 11))
    }

    func testARegionReachingAcrossTheDateLineIsNotOneBoxRoundTheWorld() throws {
        // Rings either side of 180°: one box around them all spans the globe, and
        // elevation is fetched cell by cell.
        let antimeridian: [String: Any] = [
            "properties": ["id": "continent/antimeridian-region", "name": "Antimeridian Region"],
            "geometry": ["type": "MultiPolygon",
                         "coordinates": [[ring([(177, -19), (180, -19), (180, -16),
                                                (177, -16), (177, -19)])],
                                         [ring([(-180, -19), (-178, -19), (-178, -16),
                                                (-180, -16), (-180, -19)])]]]
        ]
        let region = try XCTUnwrap(try index([antimeridian])
                                    .region("continent/antimeridian-region"))
        XCTAssertEqual(region.boxes.count, 2)
        XCTAssertEqual(region.demTileCount, 3 * 3 + 2 * 3)
        // The bbox still spans the globe; only the count of ground does not.
        XCTAssertEqual(region.bbox, box(-180, -19, 180, -16))
        XCTAssertLessThan(region.demTileCount, region.bbox.demTileCount / 20)
    }

    func testAntarcticaStaysOneRectangleFromEdgeToEdge() throws {
        // A single ring spanning the whole longitude range: a rule that looked for an
        // empty stretch of longitude would read its middle as the gap.
        let fullWidth = feature(id: "full-width-region", name: "Full Width Region",
                                geometry: [ring([(-180, -90), (180, -90), (180, -60),
                                                 (-180, -60), (-180, -90)])])
        let region = try XCTUnwrap(try index([fullWidth]).region("full-width-region"))
        XCTAssertEqual(region.boxes.count, 1)
        XCTAssertEqual(region.boxes[0], box(-180, -90, 180, -60))
        XCTAssertGreaterThan(region.demTileCount, 0)
    }

    func testARegionWithNoGeometryIsKeptWithNoCoverage() throws {
        // A grouping row carries no outline of its own; dropping it loses its children.
        let region = try XCTUnwrap(try index([feature(id: "continent", name: "Continent")])
                                    .region("continent"))
        XCTAssertFalse(region.bbox.isValid)
        XCTAssertTrue(region.boxes.isEmpty)
        XCTAssertEqual(region.demTileCount, 0)
    }

    func testCoordinatesArrivingAsNSNumberAreReadTheSameAsDoubles() throws {
        // JSONSerialization types whole numbers as NSNumber rather than Double.
        let whole: [String: Any] = [
            "properties": ["id": "x/whole", "name": "Whole"],
            "geometry": ["type": "Polygon",
                         "coordinates": [[[5, 49], [7, 49], [7, 51], [5, 51], [5, 49]]]]
        ]
        let region = try XCTUnwrap(try index([whole]).region("x/whole"))
        XCTAssertEqual(region.bbox, box(5, 49, 7, 51))
    }

    // MARK: The tree

    func testChildrenHangOffTheirParentInNameOrder() throws {
        let parsed = try index([
            feature(id: "continent", name: "Continent"),
            feature(id: "continent/region-c", name: "Region C", parent: "continent"),
            feature(id: "continent/region-a", name: "Region A", parent: "continent"),
            feature(id: "continent/region-b", name: "Region B", parent: "continent"),
        ])
        XCTAssertEqual(parsed.children(of: "continent").map(\.name),
                       ["Region A", "Region B", "Region C"])
        XCTAssertTrue(parsed.region("continent")!.hasChildren)
        XCTAssertFalse(parsed.region("continent/region-c")!.hasChildren)
        XCTAssertTrue(parsed.children(of: "continent/region-c").isEmpty)
    }

    func testTheRootsAreTheRegionsWithNoParentPresent() throws {
        // A row naming a parent the file does not contain is a root, not a lost region.
        let parsed = try index([
            feature(id: "continent", name: "Continent"),
            feature(id: "island", name: "Island"),
            feature(id: "x/orphan", name: "Orphan", parent: "nowhere"),
        ])
        XCTAssertEqual(parsed.children(of: nil).map(\.name), ["Continent", "Island", "Orphan"])
    }

    func testAncestryWalksUpAndCountsARegionAsItsOwnAncestor() throws {
        let parsed = try index([
            feature(id: "continent", name: "Continent"),
            feature(id: "continent/parent-region", name: "Parent Region", parent: "continent"),
            feature(id: "continent/parent-region/child-region", name: "Child Region",
                    parent: "continent/parent-region"),
            feature(id: "island", name: "Island"),
        ])
        XCTAssertTrue(parsed.isAncestor("continent", of: "continent/parent-region/child-region"))
        XCTAssertTrue(parsed.isAncestor("continent/parent-region",
                                        of: "continent/parent-region/child-region"))
        XCTAssertTrue(parsed.isAncestor("continent/parent-region", of: "continent/parent-region"))
        XCTAssertFalse(parsed.isAncestor("island", of: "continent/parent-region"))
        XCTAssertFalse(parsed.isAncestor("continent/parent-region/child-region", of: "continent"))
    }

    func testAFileWhereEveryRegionHasAParentIsRefusedRatherThanWalkedForEver() throws {
        // Two regions naming each other as parent leave no root at all.
        let data = try JSONSerialization.data(withJSONObject: ["features": [
            feature(id: "a", name: "A", parent: "b"),
            feature(id: "b", name: "B", parent: "a"),
        ]])
        XCTAssertThrowsError(try RegionIndex().parse(data))
    }

    func testTheAncestryWalkAndTheBreadcrumbAreBoundedWhateverTheTreeSays() throws {
        // A chain deeper than either walk's limit.
        var features: [[String: Any]] = [feature(id: "r0", name: "R0")]
        for depth in 1..<40 {
            features.append(feature(id: "r\(depth)", name: "R\(depth)",
                                    parent: "r\(depth - 1)"))
        }
        let parsed = try index(features)
        XCTAssertFalse(parsed.isAncestor("r0", of: "r39"))    // past the walk's limit
        XCTAssertTrue(parsed.isAncestor("r30", of: "r39"))
        XCTAssertFalse(parsed.breadcrumb("r39").isEmpty)
    }

    func testAHitOnTheIdIsRankedByWhereItSitsInTheIdNotInTheName() throws {
        // The match offset is measured in whichever string matched: here the id is longer
        // than its own name, so an index taken from one and used in the other is past the end.
        let parsed = try index([
            feature(id: "large-region/inland/child-region", name: "Child Region",
                    pbf: "https://x/c.osm.pbf"),
            feature(id: "in", name: "Inland", pbf: "https://x/in.osm.pbf"),
        ])
        let hits = parsed.search("inland").map(\.name)
        XCTAssertEqual(hits, ["Inland", "Child Region"])
    }

    func testTheBreadcrumbReadsFromTheWorldDown() throws {
        let parsed = try index([
            feature(id: "continent", name: "Continent"),
            feature(id: "continent/parent-region", name: "Parent Region", parent: "continent"),
            feature(id: "continent/parent-region/child-region", name: "Child Region",
                    parent: "continent/parent-region"),
        ])
        let trail = parsed.breadcrumb("continent/parent-region/child-region")
        XCTAssertTrue(trail.hasPrefix("World"), trail)
        XCTAssertTrue(trail.contains("Continent"), trail)
        XCTAssertTrue(trail.hasSuffix("Child Region"), trail)
        XCTAssertEqual(parsed.breadcrumb(nil), "World")
    }

    // MARK: Downloads

    func testTheChecksumSitsBesideTheExtractAndOnlyExistsWhenTheExtractDoes() throws {
        let parsed = try index([
            feature(id: "continent/small-region", name: "Small Region",
                    pbf: "https://download.geofabrik.de/continent/small-region-latest.osm.pbf"),
            feature(id: "continent", name: "Continent"),
        ])
        XCTAssertEqual(parsed.region("continent/small-region")?.md5URL?.absoluteString,
                       "https://download.geofabrik.de/continent/small-region-latest.osm.pbf.md5")
        XCTAssertNil(parsed.region("continent")?.md5URL)
    }

    // MARK: Search

    func testSearchPrefersAPrefixThenAShortNameThenSomethingDownloadable() throws {
        let parsed = try index([
            feature(id: "continent/coastal", name: "Coastal", pbf: "https://x/coastal.osm.pbf"),
            feature(id: "x/upper-coastal", name: "Upper Coastal", pbf: "https://x/uc.osm.pbf"),
            feature(id: "x/coastal-region", name: "Coastal Region"),   // no download
        ])
        let hits = parsed.search("coastal").map(\.name)
        XCTAssertEqual(hits.first, "Coastal")
        // The one that cannot be downloaded sinks below the ones that can.
        XCTAssertEqual(hits.last, "Coastal Region")
        XCTAssertTrue(hits.contains("Upper Coastal"))
    }

    func testSearchIgnoresCaseAndSurroundingSpaceAndMatchesTheIdToo() throws {
        let parsed = try index([
            feature(id: "large-region/inland/child-region", name: "Child Region",
                    pbf: "https://x/c.osm.pbf"),
        ])
        XCTAssertEqual(parsed.search("  CHILD REGION ").count, 1)
        XCTAssertEqual(parsed.search("inland").first?.name, "Child Region")   // by id
        XCTAssertTrue(parsed.search("").isEmpty)
        XCTAssertTrue(parsed.search("   ").isEmpty)
        XCTAssertTrue(parsed.search("nothing at all here").isEmpty)
    }

    // MARK: Refusing a file that is not the index

    func testAFileWithoutFeaturesIsRefused() throws {
        let index = RegionIndex()
        XCTAssertThrowsError(try index.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try index.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try index.parse(
            try JSONSerialization.data(withJSONObject: ["features": []])))
    }

    func testARowWithoutAnIdOrNameIsSkippedRatherThanBreakingTheFile() throws {
        let parsed = try index([
            ["properties": ["name": "No id"]],
            ["properties": ["id": "x/no-name"]],
            feature(id: "continent", name: "Continent"),
        ])
        XCTAssertEqual(parsed.regions.count, 1)
        XCTAssertNotNil(parsed.region("continent"))
    }

    func testAFailedParseLeavesTheOldIndexInPlace() throws {
        let parsed = try index([feature(id: "continent", name: "Continent")])
        XCTAssertThrowsError(try parsed.parse(Data("{}".utf8)))
        XCTAssertNotNil(parsed.region("continent"))
        XCTAssertEqual(parsed.rootIDs, ["continent"])
    }
}
