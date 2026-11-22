import XCTest

@testable import kmap

/// What a run left unsure, and which region is worth reading for it: the one whose ground
/// may settle the most of those codes, where those are enough.
final class StyleRecoveryRemainderTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-remainder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A plain, hills beside it, and a big region around both and more.
    private func index(prefix: String) throws -> RegionIndex {
        func feature(_ id: String, _ box: [Double]) -> String {
            """
            {"properties": {"id": "\(prefix)\(id)", "name": "\(id)",
              "urls": {"pbf": "https://example.org/\(id).osm.pbf"}},
             "geometry": {"coordinates": [[[\(box[0]), \(box[1])], [\(box[2]), \(box[1])],
                                           [\(box[2]), \(box[3])], [\(box[0]), \(box[3])]]]}}
            """
        }
        let json = """
            {"features": [\(feature("plain", [0, 0, 10, 10])), \(feature("hills", [20, 0, 30, 10])),
                          \(feature("big", [0, 0, 40, 20]))]}
            """
        let out = RegionIndex()
        try out.parse(Data(json.utf8))
        return out
    }

    private func tally(lon: Double, lat: Double, _ codes: [Int: Int]) -> ImgElements.Tally {
        ImgElements.Tally(
            box: BBox(minLon: lon - 0.1, minLat: lat - 0.1, maxLon: lon + 0.1, maxLat: lat + 0.1),
            codes: Dictionary(uniqueKeysWithValues: codes.map { (Evidence.slot(.point, $0.key), $0.value) })
        )
    }

    /// 5 unsettled codes of 100; those of `drawn` were never drawn on the ground read.
    private func remainder(_ drawn: [ImgElements.Tally]) -> StyleRecovery.Remainder {
        var out = StyleRecovery.Remainder(codes: 100, tooFew: 2, never: 2, mixed: 1, drawn: drawn)
        for slot in drawn.flatMap(\.codes.keys) { out.seen[slot] = StyleRecovery.Remainder.Sighting() }
        return out
    }

    private func best(
        _ left: StyleRecovery.Remainder,
        in index: RegionIndex,
        among ids: [String]? = nil
    ) -> (region: Region, codes: Int)? {
        let owners = RegionSuggestion.owners(in: index)
        return left.bestRegion(among: Set(ids ?? owners.map(\.id)), owners: owners)
    }

    func testARegionIsWorthReadingForMoreCodesThanTheForecastIsOffBy() {
        let left = remainder([])
        XCTAssertTrue(left.isWorth(3))
        XCTAssertFalse(left.isWorth(2))
        XCTAssertEqual(left.unsettled, 5)
    }

    /// The hills may settle 2 of the codes; they draw a third only 2 times, which
    /// witnesses nothing.
    func testTheBestRegionMaySettleTheMostOfTheUnsureCodes() throws {
        let prefix = "test-\(UUID().uuidString.prefix(8))/"
        let all = try index(prefix: prefix)
        let left = remainder([
            tally(lon: 5, lat: 5, [0x100: 5]),
            tally(lon: 25, lat: 5, [0x100: 3, 0x200: 4, 0x300: 2]),
            tally(lon: 35, lat: 15, [0x400: 10])
        ])
        let first = try XCTUnwrap(best(left, in: all))
        XCTAssertEqual(first.region.id, prefix + "hills")
        XCTAssertEqual(first.codes, 2)
        // Without the hills among them: the plain and the big region may each settle 1
        // code, and the big one has more elements of it.
        let next = try XCTUnwrap(best(left, in: all, among: [prefix + "plain", prefix + "big"]))
        XCTAssertEqual(next.region.id, prefix + "big")
        XCTAssertEqual(next.codes, 1)
    }

    /// A subdivision counts for the smallest region over its middle; elements of a code
    /// add up across a region's subdivisions.
    func testCountsAddUpOverARegionsSubdivisions() throws {
        let prefix = "test-\(UUID().uuidString.prefix(8))/"
        let left = remainder([
            tally(lon: 2, lat: 2, [0x100: 1]), tally(lon: 3, lat: 3, [0x100: 1]), tally(lon: 4, lat: 4, [0x100: 1])
        ])
        let first = try XCTUnwrap(best(left, in: try index(prefix: prefix)))
        XCTAssertEqual(first.region.id, prefix + "plain", "not the big region around it")
        XCTAssertEqual(first.codes, 1)
    }

    private typealias Sighting = StyleRecovery.Remainder.Sighting

    /// A code the ground read never drew may be settled where it is drawn often enough to
    /// witness.
    func testACodeNeverDrawnNeedsOnlyBeDrawnOftenEnough() {
        XCTAssertFalse(Sighting().maySettle(drawn: 2))
        XCTAssertTrue(Sighting().maySettle(drawn: 3))
    }

    /// A region is expected to show a code as the ground read did: 1 sighting in 21
    /// elements is 1 more in 21, and 3 in all take 42.
    func testACodeSeenTooLittleIsExpectedToBeSeenAsOftenAgain() {
        let rare = Sighting(elements: 21, sources: 1, meant: 1)
        XCTAssertFalse(rare.maySettle(drawn: 20), "under 1 sighting more")
        XCTAssertFalse(rare.maySettle(drawn: 41), "under 3 in all")
        XCTAssertTrue(rare.maySettle(drawn: 42))
        // 2 of 2 seen: 1 element more is the third sighting.
        XCTAssertTrue(Sighting(elements: 2, sources: 2, meant: 2).maySettle(drawn: 1))
        // 1 of 2 identified: 3 elements more are 1.5 sightings, 2.5 in all.
        XCTAssertFalse(Sighting(elements: 2, sources: 1, meant: 1).maySettle(drawn: 3))
        XCTAssertTrue(Sighting(elements: 2, sources: 1, meant: 1).maySettle(drawn: 4))
    }

    /// What the zoomed-out levels witnessed is no sighting of an element: 1 element with
    /// 4 witnesses is 1 sighting in 1, and a code drawn only there has no rate at all.
    func testWitnessesOfTheZoomedOutLevelsDoNotRaiseTheRate() {
        let coarse = Sighting(elements: 1, sources: 4, meant: 4)
        XCTAssertFalse(coarse.maySettle(drawn: 1), "2 sightings in all")
        XCTAssertTrue(coarse.maySettle(drawn: 2))
        let onlyCoarse = Sighting(elements: 0, sources: 2, meant: 2)
        XCTAssertFalse(onlyCoarse.maySettle(drawn: 2))
        XCTAssertTrue(onlyCoarse.maySettle(drawn: 3))
        XCTAssertFalse(Sighting(elements: 0, sources: 9, meant: 9, mixed: true).maySettle(drawn: 5000))
    }

    /// Nothing identified in 1 or 2 elements is no rate to go by: as a code never drawn.
    /// In 3 and more it is one, of nothing.
    func testNothingIdentifiedInTooFewElementsIsNoRate() {
        XCTAssertTrue(Sighting(elements: 2).maySettle(drawn: 3))
        XCTAssertFalse(Sighting(elements: 2).maySettle(drawn: 2))
        XCTAssertFalse(Sighting(elements: 3).maySettle(drawn: 5000))
    }

    /// A subdivision across 180 deg, its middle past it, counts for the region west of it.
    func testASubdivisionPast180CountsForTheRegionWestOfIt() throws {
        let json = """
            {"features": [{"properties": {"id": "zz-west", "name": "west",
              "urls": {"pbf": "https://example.org/west.osm.pbf"}},
             "geometry": {"coordinates": [[[-180, 0], [-170, 0], [-170, 10], [-180, 10]]]}}]}
            """
        let all = RegionIndex()
        try all.parse(Data(json.utf8))
        let slot = Evidence.slot(.point, 0x100)
        var left = StyleRecovery.Remainder(codes: 100, never: 1)
        left.seen = [slot: Sighting()]
        left.drawn = [
            ImgElements.Tally(box: BBox(minLon: 179.9, minLat: 4, maxLon: 180.5, maxLat: 6), codes: [slot: 4])
        ]
        XCTAssertEqual(best(left, in: all)?.region.id, "zz-west")
    }

    /// More of the same settles nothing where the trouble is not too few sightings:
    /// witnesses that disagree, that mostly mean nothing, or none in 40 elements.
    func testACodeLeftForAnotherReasonHasNoChance() {
        XCTAssertFalse(Sighting(elements: 9, sources: 9, meant: 9, mixed: true).maySettle(drawn: 5000))
        XCTAssertFalse(Sighting(elements: 30, sources: 30, meant: 1).maySettle(drawn: 5000))
        XCTAssertFalse(Sighting(elements: 5, sources: 5, meant: 2).maySettle(drawn: 5000))
        XCTAssertTrue(Sighting(elements: 5, sources: 4, meant: 2).maySettle(drawn: 5000), "half of them mean something")
        XCTAssertFalse(Sighting(elements: 40).maySettle(drawn: 5000))
    }

    /// The region is chosen by the codes it may settle, not by those it merely draws.
    func testTheBestRegionIsTheOneThatMaySettleTheMost() throws {
        let prefix = "test-\(UUID().uuidString.prefix(8))/"
        let all = try index(prefix: prefix)
        var left = StyleRecovery.Remainder(codes: 100, tooFew: 2, mixed: 2)
        left.seen = [
            Evidence.slot(.point, 0x100): Sighting(elements: 8, sources: 2, meant: 2),
            Evidence.slot(.point, 0x200): Sighting(elements: 5000, sources: 900, meant: 900, mixed: true),
            Evidence.slot(.point, 0x300): Sighting(elements: 30, sources: 30, meant: 1),
            Evidence.slot(.point, 0x400): Sighting(elements: 2, sources: 1, meant: 1)
        ]
        // The plain draws 3 of them in plenty and may settle none; the hills draw 2 of
        // them a little and may settle both.
        left.drawn = [
            tally(lon: 5, lat: 5, [0x100: 3, 0x200: 9000, 0x300: 9000]),
            tally(lon: 25, lat: 5, [0x100: 4, 0x400: 4])
        ]
        let first = try XCTUnwrap(best(left, in: all))
        XCTAssertEqual(first.region.id, prefix + "hills")
        XCTAssertEqual(first.codes, 2)
        XCTAssertNil(best(left, in: all, among: [prefix + "plain"]))
    }

    /// Ground under an extract that is no candidate, the cache's own, is nobody's to read
    /// again: its subdivisions do not fall through to a bigger region.
    func testGroundUnderAnExtractThatIsNoCandidateIsNotHandedOn() throws {
        let prefix = "test-\(UUID().uuidString.prefix(8))/"
        let all = try index(prefix: prefix)
        let left = remainder([tally(lon: 25, lat: 5, [0x100: 9])])
        XCTAssertNil(best(left, in: all, among: [prefix + "plain", prefix + "big"]))
    }

    func testNoRegionIsBestWhereNoneDrawsThemOftenEnough() throws {
        let all = try index(prefix: "test-\(UUID().uuidString.prefix(8))/")
        XCTAssertNil(best(remainder([]), in: all))
        XCTAssertNil(best(remainder([tally(lon: 5, lat: 5, [0x100: 2])]), in: all), "2 elements are no witness")
        XCTAssertNil(best(remainder([tally(lon: 100, lat: 50, [0x100: 9])]), in: all), "off every region")
    }

    /// The unsettled codes are those the run saw too little of, never, or with witnesses that
    /// disagree, and those the map draws only off its ground, unless a build draws them
    /// already.
    func testTheRemainderCountsWhatTheRunDidNotLearn() throws {
        let detail: [TreFixture.Detail] = [
            .init(
                lon: 10.5,
                lat: 50.5,
                halfLon: 0.2,
                halfLat: 0.2,
                points: [.init(type: 0x2a), .init(type: 0x2a), .init(type: 0x2b)]
            ),
            .init(
                lon: 12.5,
                lat: 50.5,
                halfLon: 0.2,
                halfLat: 0.2,
                points: [.init(type: 0x64), .init(type: 0x64), .init(type: 0x64), .init(type: 0x2f, sub: 0x01)]
            )
        ]
        let bounds = BBox(minLon: 10, minLat: 50, maxLon: 13, maxLat: 51)
        let img = try ImgFixture.container(
            [
                ("63000001", "TRE", TreFixture.tre(bounds: bounds, detail: detail)),
                ("63000001", "RGN", TreFixture.rgn(detail: detail))
            ],
            into: directory
        )
        func outcome(
            _ type: Int,
            _ status: StyleRecovery.Status,
            witnesses: Int,
            elements: Int
        ) -> StyleRecovery.Outcome {
            StyleRecovery.Outcome(
                kind: .point,
                type: type,
                witnesses: witnesses,
                elements: elements,
                unmatched: 0,
                ambiguous: 0,
                meaning: "",
                status: status,
                meant: witnesses
            )
        }
        // The run saw 0x2a00 once in its 1 element, settled 0x2b00, met 0x7000 on 40
        // elements that matched nothing and 0x7100 on 9 whose witnesses disagree.
        // MiniRuleBook draws 0x2f01 already.
        let left = try StyleRecovery.remainder(
            of: img,
            off: [],
            outcomes: [
                "P2a00": outcome(0x2a00, .singleWitness, witnesses: 1, elements: 1),
                "P2b00": outcome(0x2b00, .resolved, witnesses: 9, elements: 9),
                "P7000": outcome(0x7000, .noEvidence, witnesses: 0, elements: 40),
                "P7100": outcome(0x7100, .mixed, witnesses: 9, elements: 9)
            ],
            rules: try MiniRuleBook.load(),
            stop: StopFlag()
        )
        XCTAssertEqual(left.codes, 6, "4 the run met, 2 drawn only off its ground")
        XCTAssertEqual(left.tooFew, 1)
        XCTAssertEqual(left.never, 2, "0x7000 and 0x6400, and not the default 0x2f01")
        XCTAssertEqual(left.mixed, 1)
        XCTAssertEqual(left.unsettled, 4)
        XCTAssertEqual(
            left.seen,
            [
                Evidence.slot(.point, 0x2a00): Sighting(elements: 1, sources: 1, meant: 1),
                Evidence.slot(.point, 0x7000): Sighting(elements: 40),
                Evidence.slot(.point, 0x7100): Sighting(elements: 9, sources: 9, meant: 9, mixed: true),
                Evidence.slot(.point, 0x6400): Sighting()
            ]
        )
        let drawn = left.drawn.sorted { $0.box.minLon < $1.box.minLon }
        XCTAssertEqual(drawn.map(\.codes), [[Evidence.slot(.point, 0x2a00): 2], [Evidence.slot(.point, 0x6400): 3]])
    }
}
