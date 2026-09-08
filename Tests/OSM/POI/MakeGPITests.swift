import XCTest
@testable import kmap

/// Building the Custom POI file: the one Garmin format with a real description field.
///
/// A `.img` has none: its POI records carry an address block, built for a few types only,
/// which a handheld receiver need not render at all.
final class MakeGPITests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-gpi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: What is worth carrying

    func testADescriptionThatOnlyRepeatsTheNameIsNotWorthCarrying() {
        XCTAssertFalse(MakeGPI.worthCarrying("Родник Лесной", "Родник Лесной"))
        XCTAssertFalse(MakeGPI.worthCarrying("родник лесной", "Родник Лесной"))
    }

    func testAVeryShortDescriptionIsNotWorthCarrying() {
        // Under a dozen characters tells a walker nothing.
        XCTAssertFalse(MakeGPI.worthCarrying("вода", ""))
        XCTAssertFalse(MakeGPI.worthCarrying("spring", "Woodland"))
        XCTAssertTrue(MakeGPI.worthCarrying("вода круглый год, чистая", "Родник"))
    }

    func testADescriptionSayingMoreThanTheNameIsCarried() {
        XCTAssertTrue(MakeGPI.worthCarrying("Источник в буковом лесу, вода круглый год",
                                            "Родник"))
    }

    func testADescriptionThatMerelyExtendsTheNameSlightlyIsNot() {
        // Within six characters of the name and containing it: nothing new.
        XCTAssertFalse(MakeGPI.worthCarrying("Родник Лесной.", "Родник Лесной"))
    }

    func testAnObjectWithNoNameStillCarriesItsDescription() {
        XCTAssertTrue(MakeGPI.worthCarrying("Заброшенная метеостанция", ""))
    }

    // MARK: What is left out

    func testExcludesAreReadAsExactPairsOrWholeKeys() {
        let parsed = MakeGPI.parse(["amenity=bench", "barrier=*", " shop=bakery , tourism=* "])
        XCTAssertEqual(parsed.exact, ["amenity=bench", "shop=bakery"])
        XCTAssertEqual(parsed.wildcard, ["barrier", "tourism"])
    }

    func testSomethingWithoutAnEqualsSignIsNotAnExclude() {
        let parsed = MakeGPI.parse(["nonsense", ""])
        XCTAssertTrue(parsed.exact.isEmpty)
        XCTAssertTrue(parsed.wildcard.isEmpty)
    }

    // MARK: Text encoding

    func testTheDeviceCodepagesAreKnownByName() {
        XCTAssertEqual(MakeGPI.codePage(named: "cp1250"), 1250)
        XCTAssertEqual(MakeGPI.codePage(named: "cp1251"), 1251)
        XCTAssertEqual(MakeGPI.codePage(named: "cp1253"), 1253)
        XCTAssertEqual(MakeGPI.codePage(named: "cp1254"), 1254)
        XCTAssertEqual(MakeGPI.codePage(named: "utf8"), CodePage.utf8)
        XCTAssertEqual(MakeGPI.codePage(named: "utf-8"), CodePage.utf8)
        // An unrecognised name falls back to the default page.
        XCTAssertEqual(MakeGPI.codePage(named: "whatever"), 1252)
    }

    func testACyrillicNameIsWrittenAsCyrillicBytesAndNotAsNothing() {
        // The GPX carries code-page bytes disguised as Latin-1, so the byte sequence is
        // what has to survive.
        let bytes = CodePage.encode("Серна", codePage: 1251, lossy: true)
        XCTAssertEqual(bytes, [0xD1, 0xE5, 0xF0, 0xED, 0xE0])
    }

    func testANameThePageCannotSpellBecomesQuestionMarksRatherThanDisappearing() {
        XCTAssertEqual(CodePage.encode("Серна", codePage: 1252, lossy: true),
                       Array(repeating: 0x3F, count: 5))
        XCTAssertNil(CodePage.encode("Серна", codePage: 1252, lossy: false))
    }

    // MARK: Reading an extract

    /// Runs the scan over a written extract and returns the points it would carry.
    private func scan(nodes: [(id: Int64, lat: Double, lon: Double, tags: [(String, String)])],
                      ways: [(id: Int64, refs: [Int64], tags: [(String, String)])] = [],
                      exclude: [String] = []) throws -> [MakeGPI.Point] {
        let url = directory.appendingPathComponent("in.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes(nodes.map {
            PBFWriter.Node(id: $0.id, lat: $0.lat, lon: $0.lon, tags: $0.tags)
        })
        if !ways.isEmpty {
            writer.ways(ways.map { PBFWriter.Way(id: $0.id, refs: $0.refs, tags: $0.tags) })
        }
        try writer.finish()

        var found = MakeGPI.Scan(prefer: "ru", exclude: MakeGPI.parse(exclude))
        try PBFReader(url: url).readInOrder(make: {
            MakeGPI.Scan(prefer: "ru", exclude: MakeGPI.parse(exclude))
        }) { part in
            found.take(part)
            part.clear()
        }
        return try found.resolve(url: url)
    }

    func testADescribedNodeBecomesAPoint() throws {
        let points = try scan(nodes: [
            (1, 44.5, 33.5, [("natural", "spring"), ("name", "Родник"),
                             ("description", "Вода круглый год, чистая")]),
        ])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].name, "Родник")
        XCTAssertEqual(points[0].lat, 44.5, accuracy: 1e-6)
    }

    func testANodeWithNoDescriptionIsNotCarried() throws {
        let points = try scan(nodes: [
            (1, 44.5, 33.5, [("natural", "spring"), ("name", "Родник")]),
        ])
        XCTAssertTrue(points.isEmpty)
    }

    func testANodeThatIsNotAPlaceOfInterestIsNotCarried() throws {
        let points = try scan(nodes: [
            (1, 44.5, 33.5, [("ref", "42"), ("description", "Просто узел без смысла")]),
        ])
        XCTAssertTrue(points.isEmpty)
    }

    func testTheChosenLanguageWinsWhereBothAreThere() throws {
        let points = try scan(nodes: [
            (1, 44.5, 33.5, [("tourism", "viewpoint"), ("name", "Вид"),
                             ("description:en", "A wide view over the valley"),
                             ("description:ru", "Широкий вид на долину")]),
        ])
        XCTAssertEqual(points.first?.description, "Широкий вид на долину")
    }

    func testAnExcludedObjectIsLeftOut() throws {
        // Whatever is hidden on the map is hidden here too, or the choice is undone by
        // the same objects reappearing under Custom POIs.
        let points = try scan(nodes: [
            (1, 44.5, 33.5, [("amenity", "bench"),
                             ("description", "Скамейка с видом на море")]),
        ], exclude: ["amenity=bench"])
        XCTAssertTrue(points.isEmpty)
    }

    func testAWholeKeyCanBeExcluded() throws {
        let points = try scan(nodes: [
            (1, 44.5, 33.5, [("shop", "bakery"),
                             ("description", "Свежий хлеб каждое утро")]),
        ], exclude: ["shop=*"])
        XCTAssertTrue(points.isEmpty)
    }

    func testAnAreaIsCarriedAtTheCentreOfItsBox() throws {
        let points = try scan(nodes: [
            (1, 44.0, 33.0, []), (2, 44.0, 33.02, []),
            (3, 44.02, 33.02, []), (4, 44.02, 33.0, []),
        ], ways: [
            (10, [1, 2, 3, 4, 1], [("historic", "ruins"), ("name", "Крепость"),
                                   ("description", "Развалины старой крепости")]),
        ])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].lat, 44.01, accuracy: 1e-6)
        XCTAssertEqual(points[0].lon, 33.01, accuracy: 1e-6)
    }

    func testAnUnnamedObjectIsCalledWhatItIs() throws {
        // So the list under Custom POIs is navigable.
        let points = try scan(nodes: [
            (1, 44.5, 33.5, [("man_made", "water_well"),
                             ("description", "Старый колодец, вода солоноватая")]),
        ])
        XCTAssertEqual(points.first?.name, "water well")
    }

    func testManyDescribedObjectsAcrossManyBlocks() throws {
        var nodes: [(id: Int64, lat: Double, lon: Double, tags: [(String, String)])] = []
        for i in Int64(1)...12_000 {
            nodes.append((i, 44 + Double(i) * 1e-5, 33,
                          [("tourism", "viewpoint"), ("name", "Точка \(i)"),
                           ("description", "Описание с видом номер \(i) на долину")]))
        }
        let points = try scan(nodes: nodes)
        XCTAssertEqual(points.count, 12_000)
    }
}
