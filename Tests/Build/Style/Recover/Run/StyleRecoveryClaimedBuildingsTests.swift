import XCTest

@testable import kmap

/// Which of their codes draws a building another rule claims, read from the sources.
final class StyleRecoveryClaimedBuildingsTests: XCTestCase {
    private static let claimants: Set<String> = ["amenity", "shop", "historic", "parking"]

    /// An area code with sources `ids`, each carrying `tags`.
    private func code(_ type: Int, _ groups: [(ids: ClosedRange<Int>, tags: [String: String])]) -> Evidence.ForCode {
        var code = Evidence.ForCode(kind: .area, type: type)
        for group in groups {
            for id in group.ids {
                code.sources[Int64(id)] = group.tags
                code.extent[Int64(id)] = 10
            }
        }
        return code
    }

    private let hall = ["amenity": "townhall", "building": "yes"]
    private let school = ["amenity": "school", "building": "school"]
    private let grounds = ["amenity": "townhall"]
    private let bakery = ["shop": "bakery", "building": "retail"]
    private let castle = ["historic": "castle", "building": "yes"]
    private let house = ["building": "yes"]

    private func layer(_ codes: [String: Evidence.ForCode]) -> (code: String?, drawn: Int, buildings: Int) {
        StyleRecovery.claimedBuildingCode(in: Array(Evidence(codes: codes).codes), claimedBy: Self.claimants)
    }

    /// Their map with a layer like ours: the claimant's area, and 1 code over every
    /// claimed building whatever the claimant.
    private var layered: [String: Evidence.ForCode] {
        [
            "A23": code(0x23, [(1...40, hall), (41...60, grounds)]),
            "A8": code(0x08, [(101...150, bakery)]),
            "A36": code(0x36, [(1...40, hall), (101...150, bakery)]),
            "A13": code(0x13, [(201...900, house)])
        ]
    }

    func testABuildingIsClaimedByTheFirstKeyARuleDrawsBy() {
        let order = StyleRecovery.claimOrder(Self.claimants)
        XCTAssertEqual(order, ["amenity", "shop", "historic", "parking"], "meanings as they are read, then the rest")
        XCTAssertEqual(StyleRecovery.claimant(of: hall, among: order), "amenity=townhall")
        XCTAssertEqual(
            StyleRecovery.claimant(of: ["shop": "kiosk", "historic": "yes", "building": "yes"], among: order),
            "shop=kiosk"
        )
        XCTAssertEqual(
            StyleRecovery.claimant(of: ["parking": "multi-storey", "building": "yes"], among: order),
            "parking=multi-storey",
            "a key that is no meaning claims too"
        )
        XCTAssertNil(StyleRecovery.claimant(of: grounds, among: order), "no building")
        XCTAssertNil(StyleRecovery.claimant(of: house, among: order), "nothing claims it")
        XCTAssertNil(StyleRecovery.claimant(of: ["amenity": "cafe", "building": "no"], among: order))
        XCTAssertNil(StyleRecovery.claimant(of: ["tourism": "hotel", "building": "yes"], among: order))
    }

    func testTheCodeDrawingClaimedBuildingsWhateverClaimsThemIsTheLayer() {
        let found = layer(layered)
        XCTAssertEqual(found.code, "A36")
        XCTAssertEqual(found.drawn, 90)
        XCTAssertEqual(found.buildings, 90, "a source under 2 codes is 1 building")
    }

    /// A map that draws a building first: the building's code draws the claimed ones too.
    func testTheirBuildingCodeIsTheLayerWhereTheyDrawTheBuildingFirst() {
        let found = layer([
            "A23": code(0x23, [(41...60, grounds)]),
            "A13": code(0x13, [(1...40, hall), (101...150, bakery), (201...900, house)])
        ])
        XCTAssertEqual(found.code, "A13")
    }

    /// A map that draws what claims the building and no building: the picture changes
    /// with the claimant, so none is the building's.
    func testAPictureThatChangesWithTheClaimantIsNoLayer() {
        let found = layer([
            "A23": code(0x23, [(1...40, hall), (41...60, grounds)]),
            "A8": code(0x08, [(101...150, bakery)]),
            "A13": code(0x13, [(201...900, house)])
        ])
        XCTAssertNil(found.code)
        XCTAssertEqual(found.buildings, 90)
    }

    /// Claimants of 1 key cannot show the picture is the building's: the amenity's own
    /// colour draws every one of them too.
    func testClaimantsOfOneKeyShowNothing() {
        XCTAssertNil(layer(["A23": code(0x23, [(1...40, hall), (41...60, grounds)])]).code)
        // Even beside a real layer: the 2 codes draw the same buildings.
        XCTAssertNil(
            layer([
                "A23": code(0x23, [(1...40, hall), (301...320, school)]),
                "A36": code(0x36, [(1...40, hall), (301...320, school)])
            ]).code
        )
    }

    /// A map that draws buildings first, but a school's in the colour of its grounds:
    /// a layer over every claimed building would paint the schools as it does not.
    func testAClaimantTheCodeDoesNotDrawIsAVeto() {
        let found = layer([
            "Aa": code(0x0a, [(301...320, school)]),
            "A13": code(0x13, [(1...40, hall), (101...150, bakery), (201...900, house)])
        ])
        XCTAssertNil(found.code)
    }

    /// A claimant seen on fewer buildings than a picture is ported for has no say.
    func testAClaimantSeenTooLittleHasNoSay() {
        var codes = layered
        codes["A22"] = code(0x22, [(401...402, castle)])
        XCTAssertEqual(layer(codes).code, "A36")
    }

    func testNoClaimantsNoAreasNoLayer() {
        let none = StyleRecovery.claimedBuildingCode(in: Array(Evidence(codes: layered).codes), claimedBy: [])
        XCTAssertNil(none.code)
        XCTAssertEqual(none.buildings, 0)
        var line = Evidence.ForCode(kind: .line, type: 0x36)
        for id in 1...40 { line.sources[Int64(id)] = hall }
        XCTAssertEqual(layer(["L36": line]).buildings, 0)
    }

    /// The layer's code counts for the claimed building alone: the town hall's own look
    /// is what draws its area, with or without a building on it.
    func testTheLedgerKeepsTheBuildingApartFromWhatClaimsIt() throws {
        var report = StyleRecovery.Report()
        let found = try StyleRecovery.ledger(Evidence(codes: layered), into: &report, claimedBy: Self.claimants)
        XCTAssertEqual(found.code, "A36")
        XCTAssertEqual(report.codesByTag[StylePort.claimedBuilding], ["A36": 90])
        XCTAssertEqual(report.areaByTag[StylePort.claimedBuilding]?["A36"], 900)
        XCTAssertEqual(report.codesByTag["amenity=townhall"], ["A23": 60])
        XCTAssertEqual(report.codesByTag["shop=bakery"], ["A8": 50])
        XCTAssertEqual(report.codesByTag["building=yes"], ["A13": 700])
        XCTAssertEqual(report.groundTags[StylePort.claimedBuilding], 90)
    }

    /// With no layer in their map every source counts for its own meaning, exactly as
    /// with no claimants given.
    func testWithoutALayerEverySourceCountsForItsMeaning() throws {
        let evidence = Evidence(codes: [
            "A23": code(0x23, [(1...40, hall), (41...60, grounds)]),
            "A8": code(0x08, [(101...150, bakery)]),
            "A13": code(0x13, [(201...900, house)])
        ])
        var with = StyleRecovery.Report(), without = StyleRecovery.Report()
        try StyleRecovery.ledger(evidence, into: &with, claimedBy: Self.claimants)
        try StyleRecovery.ledger(evidence, into: &without)
        XCTAssertNil(with.codesByTag[StylePort.claimedBuilding])
        XCTAssertEqual(with.codesByTag, without.codesByTag)
        XCTAssertEqual(with.areaByTag, without.areaByTag)
        XCTAssertEqual(with.codesByTag["amenity=townhall"], ["A23": 60])
    }

    func testARaisedStopThrowsWithClaimantsToo() {
        let stop = StopFlag()
        stop.raise()
        var report = StyleRecovery.Report()
        XCTAssertThrowsError(
            try StyleRecovery.ledger(Evidence(codes: layered), into: &report, claimedBy: Self.claimants, stop: stop)
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(report.codesByTag.isEmpty)
    }
}
