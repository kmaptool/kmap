import XCTest

@testable import kmap

/// Which regions recover reads for a map.
///
/// The rules under test: ground the map has data on, never ground its tiles merely span;
/// each piece of it for 1 extract, one in the cache or else the smallest over it; and a
/// region read as itself only where most of what it holds of the map is its own ground.
final class RegionSuggestionGroundTests: XCTestCase {
    private func index() throws -> RegionIndex {
        func feature(_ id: String, _ parent: String?, box: [Double]) -> String {
            let parentLine = parent.map { "\"parent\": \"\($0)\"," } ?? ""
            return """
                {"properties": {"id": "\(id)", "name": "\(id)", \(parentLine)
                  "urls": {"pbf": "https://example.org/\(id).osm.pbf"}},
                 "geometry": {"coordinates": [[[\(box[0]), \(box[1])], [\(box[2]), \(box[1])],
                                               [\(box[2]), \(box[3])], [\(box[0]), \(box[3])]]]}}
                """
        }
        // 2 rings, 1 either side of the 180th meridian: the single box around them spans
        // the globe.
        let antimeridian = """
            {"properties": {"id": "antimeridian", "name": "antimeridian",
              "urls": {"pbf": "https://example.org/antimeridian.osm.pbf"}},
             "geometry": {"coordinates": [
                [[[-180, 51], [-130, 51], [-130, 71], [-180, 71]]],
                [[[172, 51], [180, 51], [180, 71], [172, 71]]]]}}
            """
        let json = """
            {"features": [
              \(feature("continent", nil, box: [19, 41, 180, 82])),
              \(feature("coastal", "continent", box: [32, 44, 37, 46.5])),
              \(feature("exclave", "continent", box: [19.41, 54.32, 22.89, 55.39])),
              \(feature("inland", "continent", box: [27, 56, 36, 62])),
              \(feature("south", "continent", box: [36, 43, 50, 51])),
              \(feature("neighbour", nil, box: [23.3, 57.5, 26.9, 59.7])),
              \(feature("district", "continent", box: [60, 50, 80, 60])),
              \(feature("enclave", "district", box: [61, 51, 62, 52])),
              \(antimeridian)
            ]}
            """
        let out = RegionIndex()
        try out.parse(Data(json.utf8))
        return out
    }

    private func box(_ b: [Double]) -> BBox { BBox(minLon: b[0], minLat: b[1], maxLon: b[2], maxLat: b[3]) }

    /// A map drawn evenly over the given rectangles, each spot weighted by its area. Its
    /// tiles are the rectangles themselves, or those given.
    private func drawn(_ boxes: [[Double]], tiles: [[Double]]? = nil) -> RegionSuggestion.DrawnGround {
        RegionSuggestion.DrawnGround(
            spots: boxes.map { .init(box: box($0), weight: box($0).squareDegrees) },
            tiles: (tiles ?? boxes).map(box)
        )
    }

    private func read(_ ground: RegionSuggestion.DrawnGround) throws -> [String] {
        RegionSuggestion.groundToRead(for: ground, index: try index()).map(\.region.id)
    }

    // MARK: Ground to read

    func testAMapTheSizeOfOneRegionReadsThatRegion() throws {
        XCTAssertEqual(try read(drawn([[33, 44.3, 36.6, 46.2]])), ["coastal"])
    }

    /// A region the map covers only in part counts too, the biggest share of the map's
    /// data first.
    func testEveryRegionTheMapDrawsOnIsGroundToRead() throws {
        let ground = drawn([[33, 44.3, 36.6, 46.2], [40, 45, 44, 48]])
        let order = RegionSuggestion.groundToRead(for: ground, index: try index())
        XCTAssertEqual(order.map(\.region.id), ["south", "coastal"])
        XCTAssertGreaterThan(order[0].share, order[1].share)
        XCTAssertEqual(order.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
    }

    /// A region whose only child holds a corner of it is still the extract to read for
    /// the rest.
    func testARegionStandsForTheGroundItsChildLeaves() throws {
        let ground = drawn([[60, 50, 80, 60]])
        let order = RegionSuggestion.groundToRead(for: ground, index: try index())
        XCTAssertEqual(order.map(\.region.id), ["district", "enclave"])
        // Sampled: the enclave's 1 square degree of 200 catches 3 samples of 576.
        XCTAssertEqual(order[0].share, 0.995, accuracy: 0.001)
        XCTAssertEqual(order[1].share, 0.005, accuracy: 0.001)
        XCTAssertEqual(order[0].share + order[1].share, 1, accuracy: 1e-9)
        XCTAssertEqual(order[0].whole, 1, accuracy: 1e-9, "the enclave lies in its outline too")
        XCTAssertEqual(order[0].inside, 1, accuracy: 1e-9)
        XCTAssertTrue(order[0].standsAlone)
    }

    /// Where smaller extracts hold most of what a region holds of the map, they are read,
    /// and the region is only named: its extract would be read for the strip between them.
    func testARegionTheMapNeedsOnlyInPartsIsNotReadWhole() throws {
        // The inland region with a margin on 3 sides: 54 square degrees of 70.
        let ground = drawn([[27, 55.5, 37, 62.5]])
        XCTAssertEqual(try read(ground), ["inland"])
        let named = RegionSuggestion.groundToName(for: ground, index: try index())
        XCTAssertEqual(named.map(\.region.id), ["inland", "continent"])
        XCTAssertEqual(named[1].whole, 1, accuracy: 1e-9)
        // Sampled 20 to a side: 76 of 400 samples lie off the inland region.
        XCTAssertEqual(named[1].share, 0.19, accuracy: 1e-9)
        XCTAssertFalse(named[1].standsAlone)
    }

    /// Smaller by its outline, whatever the index's tree says: `neighbour` has no parent
    /// and lies inside `continent`.
    func testGroundGoesToTheSmallestExtractOverItWhateverItsParent() throws {
        let ground = drawn([[23.5, 57.6, 26.8, 59.6]])
        XCTAssertEqual(try read(ground), ["neighbour"])
        let continent = try XCTUnwrap(
            RegionSuggestion.stances(ofExtractsIn: try index(), on: ground).first { $0.region.id == "continent" }
        )
        XCTAssertEqual(continent.share, 0)
        XCTAssertEqual(continent.whole, 1, accuracy: 1e-9)
    }

    /// Ground only a big extract holds is read as that extract.
    func testGroundNoSmallerExtractHoldsGoesToTheOneAroundIt() throws {
        let order = RegionSuggestion.groundToRead(for: drawn([[100, 60, 110, 65]]), index: try index())
        XCTAssertEqual(order.map(\.region.id), ["continent"])
        XCTAssertEqual(order[0].share, 1, accuracy: 1e-9)
    }

    /// A map reaching across 2 regions and the ground between them that only the extract
    /// around them holds: all 3 are read.
    func testAMapOverSeveralRegionsReadsEachForItsOwnGround() throws {
        XCTAssertEqual(Set(try read(drawn([[10, 43, 40, 50]]))), ["coastal", "south", "continent"])
    }

    /// A tile's rectangle spans ground the map has no data on: that ground is nobody's.
    func testGroundATileSpansWithNoDataOnItIsNotRead() throws {
        XCTAssertEqual(try read(drawn([[33, 44.3, 36.6, 46.2]], tiles: [[30, 43, 60, 50]])), ["coastal"])
    }

    /// A far tile and the map's mass: both are ground, the neighbour between them under
    /// no data is not.
    func testGroundBetweenTheMapsPartsIsNotRead() throws {
        XCTAssertEqual(try read(drawn([[19.5, 54.3, 23, 55.5], [27, 56, 36, 62]])), ["inland", "exclave"])
    }

    /// A map claiming a hair more ground than its own extract has (54.27 against 54.32):
    /// the strip around it is no reason to read the region around.
    func testAMapOvershootingItsRegionStillReadsThatRegion() throws {
        XCTAssertEqual(try read(drawn([[19.56, 54.27, 22.90, 55.42]])), ["exclave"])
    }

    /// A tile rectangle overlapping a neighbour carries almost no weight there, so the
    /// neighbour is not ground.
    func testABorderTileDoesNotMakeANeighbourIntoGround() throws {
        let spots: [RegionSuggestion.DrawnGround.Spot] = [
            .init(box: box([27, 56, 36, 62]), weight: 1000),  // the map's mass
            .init(box: box([26.8, 57, 27.5, 60]), weight: 2)  // a thin border tile
        ]
        let ground = RegionSuggestion.DrawnGround(spots: spots, tiles: spots.map(\.box))
        XCTAssertEqual(try read(ground), ["inland"])
        XCTAssertTrue(
            RegionSuggestion.groundToName(for: ground, index: try index()).contains { $0.region.id == "neighbour" },
            "it holds a little of the map all the same"
        )
    }

    /// A map drawing on no region densely enough has no ground to read, and regions to name.
    func testGroundDrawnOnThinlyIsOnlyNamed() throws {
        // 1 dense spot off every region, and a sparse one over the neighbour.
        let spots: [RegionSuggestion.DrawnGround.Spot] = [
            .init(box: box([0, 0, 1, 1]), weight: 1000), .init(box: box([23.5, 57.6, 26.8, 59.6]), weight: 1)
        ]
        let ground = RegionSuggestion.DrawnGround(spots: spots, tiles: spots.map(\.box))
        XCTAssertEqual(try read(ground), [])
        XCTAssertEqual(RegionSuggestion.groundToName(for: ground, index: try index()).map(\.region.id), ["neighbour"])
    }

    // MARK: 180 deg

    func testAnAntimeridianRegionCoversOnlyItsOwnGround() throws {
        XCTAssertEqual(try read(drawn([[-160, 60, -150, 65]])), ["antimeridian"])
        XCTAssertFalse(try read(drawn([[19.56, 54.27, 22.90, 55.42]])).contains("antimeridian"))
    }

    /// A map across 180 deg states its east edge past 180: both sides are its ground.
    func testAMapAcrossTheAntimeridianDrawsOnBothSides() throws {
        let ground = drawn([[175, 55, 185, 65]])
        XCTAssertEqual(ground.tiles.count, 2)
        let order = RegionSuggestion.groundToRead(for: ground, index: try index())
        XCTAssertEqual(order.map(\.region.id), ["antimeridian"])
        XCTAssertEqual(order[0].share, 1, accuracy: 1e-9)
        // 50 square degrees of each ring lie under the map, of 160 and 1000.
        XCTAssertEqual(order[0].inside, 100.0 / 1160, accuracy: 0.01)
    }

    // MARK: Order

    /// A point counts for the first extract holding it, and for no other; its outline's
    /// whole share is counted all the same.
    func testAPointCountsForTheFirstExtractHoldingIt() throws {
        let all = try index()
        let pair = [try XCTUnwrap(all.region("enclave")), try XCTUnwrap(all.region("district"))]
        let ground = drawn([[60, 50, 80, 60]])
        let smallestFirst = RegionSuggestion.stances(of: pair, on: ground)
        XCTAssertEqual(smallestFirst.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(smallestFirst[0].share, 0.005, accuracy: 0.001)
        let biggestFirst = RegionSuggestion.stances(of: pair.reversed(), on: ground)
        XCTAssertEqual(biggestFirst[0].share, 1, accuracy: 1e-9)
        XCTAssertEqual(biggestFirst[1].share, 0, "the district took the enclave's ground first")
        XCTAssertEqual(biggestFirst[1].whole, 0.005, accuracy: 0.001)
        XCTAssertEqual(biggestFirst[1].inside, 0, "and left it no ground of its own")
        // Alone, a region is measured over its whole outline.
        XCTAssertEqual(RegionSuggestion.stance(of: pair[1], on: ground).share, 1, accuracy: 1e-9)
        XCTAssertEqual(RegionSuggestion.share(of: ground, on: pair), 1, accuracy: 1e-9)
        XCTAssertEqual(RegionSuggestion.share(of: ground, on: [pair[0]]), 0.005, accuracy: 0.001)
    }

    // MARK: The cache

    /// Puts an extract of the fixture's region in the cache, for the length of the test.
    private func cache(_ id: String, readable: Bool = true) throws {
        let extract = RegionSuggestion.cacheDestination(for: try XCTUnwrap(index().region(id)))
        addTeardownBlock { FileTools.removeIfPresent(extract) }
        Paths.ensure(extract.deletingLastPathComponent())
        guard readable else { return try FileTools.write(Data([1, 2, 3]), to: extract) }
        let writer = try PBFWriter(to: extract)
        writer.header()
        try writer.finish()
    }

    /// What an extract in the cache holds is read already: a smaller region inside it has
    /// no ground of its own left to download for.
    func testGroundUnderACachedExtractIsNotAskedForAgain() throws {
        let ground = drawn([[33, 44.3, 36.6, 46.2]])
        XCTAssertEqual(try read(ground), ["coastal"])
        try cache("continent")
        XCTAssertEqual(try read(ground).filter { $0 != "continent" }, [])
        let named = RegionSuggestion.groundToName(for: ground, index: try index())
        XCTAssertEqual(named.map(\.region.id), ["continent"], "the cached extract holds it all")
    }

    /// What a run is fetched: the regions holding the most of the map, as many as bring
    /// the ground to a quarter of it, the cache's part counted in.
    func testAsManyRegionsAreFetchedAsHoldAQuarterOfTheMap() throws {
        // 5 regions, a fifth of the map each: by share and then by name.
        let fifths = drawn([
            [32, 44, 37, 46], [19.5, 54.4, 22.8, 55.3], [27, 56, 32, 58], [40, 44, 45, 46], [62, 53, 67, 55]
        ])
        let all = try index()
        let picks = RegionSuggestion.groundToFetch(for: fifths, index: all)
        XCTAssertEqual(picks.count, 2, "\(picks.map(\.region.id))")
        XCTAssertGreaterThanOrEqual(picks.map(\.share).reduce(0, +), StyleRecovery.leastShare)
        // With 1 of the 5 in the cache, 1 more brings it past a quarter.
        try cache("coastal")
        let more = RegionSuggestion.groundToFetch(for: fifths, index: all)
        XCTAssertEqual(more.count, 1, "\(more.map(\.region.id))")
        XCTAssertNotEqual(more.first?.region.id, "coastal")
        // A map 1 region holds whole needs that region alone.
        FileTools.removeIfPresent(RegionSuggestion.cacheDestination(for: try XCTUnwrap(all.region("coastal"))))
        XCTAssertEqual(
            RegionSuggestion.groundToFetch(for: drawn([[33, 44.3, 36.6, 46.2]]), index: all).map(\.region.id),
            ["coastal"]
        )
    }

    /// An extract in the cache that is a region of the index is read wherever the map
    /// has data on its outline, however little; one the map does not reach is not.
    func testACachedRegionIsReadByItsOutline() throws {
        try cache("coastal")
        try cache("inland")
        // Mostly east of the coastal region, 1 part in 20 on it.
        let ground = drawn([[36.5, 44.5, 37, 46], [40, 44, 44, 49]])
        let mine = ["coastal.osm.pbf", "inland.osm.pbf"]
        let read = RegionSuggestion.cachedExtracts(drawnOn: ground, index: try index())
            .filter { mine.contains($0.file.lastPathComponent) }
        XCTAssertEqual(read.map(\.file.lastPathComponent), ["coastal.osm.pbf"])
        XCTAssertEqual(read.first?.outline?.id, "coastal")
        let held = RegionSuggestion.cachedGrounds(index: try index()).filter {
            mine.contains($0.file.lastPathComponent)
        }
        XCTAssertEqual(held.map(\.known), [true, true])
    }

    /// An extract in the cache that is no region of the index holds the ground of its
    /// header's box, and is read only where the map draws enough there.
    func testACachedFileTheIndexDoesNotKnowGoesByItsBox() throws {
        let name = "zz-own-\(UUID().uuidString.prefix(8)).osm.pbf"
        let extract = Paths.pbfCache.appendingPathComponent(name)
        addTeardownBlock { FileTools.removeIfPresent(extract) }
        Paths.ensure(Paths.pbfCache)
        let writer = try PBFWriter(to: extract)
        writer.header(bbox: (minLat: 10, minLon: 100, maxLat: 12, maxLon: 103))
        try writer.finish()
        let held = try XCTUnwrap(
            RegionSuggestion.cachedGrounds(index: try index()).first { $0.file.lastPathComponent == name }
        )
        XCTAssertFalse(held.known)
        XCTAssertEqual(held.ground.bbox.minLon, 100, accuracy: 1e-6)
        XCTAssertEqual(held.ground.bbox.maxLat, 12, accuracy: 1e-6)
        let on = RegionSuggestion.cachedExtracts(drawnOn: drawn([[100.5, 10.5, 102.5, 11.5]]), index: try index())
        XCTAssertEqual(on.filter { $0.file.lastPathComponent == name }.count, 1)
        XCTAssertNil(on.first { $0.file.lastPathComponent == name }?.outline, "a box is no outline")
        let off = RegionSuggestion.cachedExtracts(drawnOn: drawn([[33, 44.3, 36.6, 46.2]]), index: try index())
        XCTAssertFalse(off.contains { $0.file.lastPathComponent == name })
    }

    /// A file under a region's name that does not read as an extract holds no ground.
    func testAFileThatDoesNotReadIsNoExtract() throws {
        try cache("coastal", readable: false)
        let held = RegionSuggestion.cachedGrounds(index: try index())
        XCTAssertFalse(held.contains { $0.file.lastPathComponent == "coastal.osm.pbf" })
        XCTAssertEqual(try read(drawn([[33, 44.3, 36.6, 46.2]])), ["coastal"], "still ground to download")
    }

    func testARegionIsCachedOnceItsExtractIsWhereABuildLooks() throws {
        let region = Region(
            id: "test/cached-\(UUID().uuidString.prefix(8))",
            name: "Cached",
            parentID: nil,
            pbfURL: nil,
            bbox: .empty,
            boxes: []
        )
        let extract = RegionSuggestion.cacheDestination(for: region)
        addTeardownBlock { FileTools.removeIfPresent(extract) }
        XCTAssertFalse(RegionSuggestion.isCached(region))
        Paths.ensure(extract.deletingLastPathComponent())
        try FileTools.write(Data([1]), to: extract)
        XCTAssertTrue(RegionSuggestion.isCached(region))
    }

    func testTheDownloadLandsWhereABuildLooks() throws {
        let coastal = try XCTUnwrap(index().region("coastal"))
        XCTAssertEqual(RegionSuggestion.cacheDestination(for: coastal).lastPathComponent, "coastal.osm.pbf")
        XCTAssertEqual(RegionSuggestion.cacheDestination(for: coastal).deletingLastPathComponent(), Paths.pbfCache)
    }

    /// The recover offer and a build land the same file beside the same cache copy, so they
    /// wait on 1 lock rather than writing it at once.
    func testTheOfferFetchesIntoTheSameCacheFileABuildDoes() {
        let region = Region(id: "europe/monaco", name: "Monaco", parentID: nil, pbfURL: nil, bbox: .empty, boxes: [])
        XCTAssertEqual(RegionSuggestion.cacheDestination(for: region), Paths.cachedExtract(forRegion: region.id))
    }
}
