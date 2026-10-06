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
        // A single word under 12 characters tells a walker nothing.
        XCTAssertFalse(MakeGPI.worthCarrying("вода", ""))
        XCTAssertFalse(MakeGPI.worthCarrying("spring", "Woodland"))
        XCTAssertTrue(MakeGPI.worthCarrying("вода круглый год, чистая", "Родник"))
        // A short phrase does say something.
        XCTAssertTrue(MakeGPI.worthCarrying("Вино и рыба", "Ресторан"))
    }

    func testADescriptionSayingMoreThanTheNameIsCarried() {
        XCTAssertTrue(
            MakeGPI.worthCarrying(
                "Источник в буковом лесу, вода круглый год",
                "Родник"
            )
        )
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

    /// The file is dated by its data, so the same extracts give the same bytes.
    func testTheFileIsDatedByItsData() throws {
        let extract = FileManager.default.temporaryDirectory.appendingPathComponent("gpi-date-\(UUID().uuidString)")
        try FileTools.write("x", to: extract)
        defer { FileTools.removeIfPresent(extract) }
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: then], ofItemAtPath: extract.path)
        XCTAssertEqual(MakeGPI.dataDate(of: [extract], environment: [:]), then)
        XCTAssertEqual(
            MakeGPI.dataDate(of: [extract], environment: ["SOURCE_DATE_EPOCH": "1600000000"]),
            Date(timeIntervalSince1970: 1_600_000_000)
        )
    }

    func testTheDeviceCodepagesAreKnownByName() {
        XCTAssertEqual(MakeGPI.codePage(named: "cp1250"), 1250)
        XCTAssertEqual(MakeGPI.codePage(named: "cp1251"), 1251)
        XCTAssertEqual(MakeGPI.codePage(named: "cp1253"), 1253)
        XCTAssertEqual(MakeGPI.codePage(named: "cp1254"), 1254)
        XCTAssertEqual(MakeGPI.codePage(named: "utf8"), CodePage.utf8)
        XCTAssertEqual(MakeGPI.codePage(named: "utf-8"), CodePage.utf8)
        // As the build's --code-page writes it, and in capitals.
        XCTAssertEqual(MakeGPI.codePage(named: "1251"), 1251)
        XCTAssertEqual(MakeGPI.codePage(named: "CP1251"), 1251)
        XCTAssertEqual(MakeGPI.codePage(named: "cp1252"), 1252)
        // One with no table is refused, not quietly western European with "?" for letters.
        XCTAssertNil(MakeGPI.codePage(named: "whatever"))
        XCTAssertNil(MakeGPI.codePage(named: "cp1255"))
    }

    func testACyrillicNameIsWrittenAsCyrillicBytesAndNotAsNothing() {
        // The GPX carries code-page bytes disguised as Latin-1, so the byte sequence is
        // what has to survive.
        let bytes = CodePage.encode("Серна", codePage: 1251, lossy: true)
        XCTAssertEqual(bytes, [0xD1, 0xE5, 0xF0, 0xED, 0xE0])
    }

    func testANameThePageCannotSpellBecomesQuestionMarksRatherThanDisappearing() {
        XCTAssertEqual(
            CodePage.encode("Серна", codePage: 1252, lossy: true),
            Array(repeating: 0x3F, count: 5)
        )
        XCTAssertNil(CodePage.encode("Серна", codePage: 1252, lossy: false))
    }

    // MARK: Reading an extract

    /// Runs the scan over a written extract and returns the points it would carry.
    private func scan(
        nodes: [(id: Int64, lat: Double, lon: Double, tags: [(String, String)])],
        ways: [(id: Int64, refs: [Int64], tags: [(String, String)])] = [],
        relations: [PBFWriter.Relation] = [],
        exclude: [String] = [],
        prefer: String = "ru"
    ) throws -> [MakeGPI.Point] {
        let url = directory.appendingPathComponent("in.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes(
            nodes.map {
                PBFWriter.Node(id: $0.id, lat: $0.lat, lon: $0.lon, tags: $0.tags)
            }
        )
        if !ways.isEmpty {
            writer.ways(ways.map { PBFWriter.Way(id: $0.id, refs: $0.refs, tags: $0.tags) })
        }
        if !relations.isEmpty { writer.relations(relations) }
        try writer.finish()

        var found = MakeGPI.Scan(prefer: prefer, exclude: MakeGPI.parse(exclude))
        var ranges: [ClosedRange<Int64>?] = []
        try PBFReader(url: url).readInOrder(make: {
            MakeGPI.Scan(prefer: prefer, exclude: MakeGPI.parse(exclude))
        }) { part in
            ranges.append(part.wayIDs)
            found.take(part)
            part.clear()
        }
        try found.addMultipolygons(urls: [url], blobWays: [ranges])
        return try found.resolve(urls: [url])
    }

    func testTwoOverlappingExtractsWriteABorderPointOnce() throws {
        // Geofabrik regions overlap at their borders: a joined map reads the same
        // described node from each extract, and the .gpi must carry it once.
        var urls: [URL] = []
        for name in ["a", "b"] {
            let url = directory.appendingPathComponent("\(name).osm.pbf")
            let writer = try PBFWriter(to: url)
            writer.header()
            writer.nodes([
                PBFWriter.Node(
                    id: 1,
                    lat: 44.5,
                    lon: 33.5,
                    tags: [("tourism", "viewpoint"), ("name", "Ай-Петри"), ("description", "вид на море и горы")]
                ),
                PBFWriter.Node(
                    id: name == "a" ? 2 : 3,
                    lat: 44.6,
                    lon: 33.6,
                    tags: [("natural", "spring"), ("name", name), ("description", "вода круглый год")]
                )
            ])
            try writer.finish()
            urls.append(url)
        }
        var gpi = MakeGPI(sources: urls, destination: directory.appendingPathComponent("out.gpi"))
        gpi.codepage = "cp1251"
        let report = try gpi.run()
        XCTAssertEqual(report.written, 3, "the shared point once, the two others each")
    }

    func testADescribedNodeBecomesAPoint() throws {
        let points = try scan(nodes: [
            (
                1, 44.5, 33.5,
                [
                    ("natural", "spring"), ("name", "Родник"),
                    ("description", "Вода круглый год, чистая")
                ]
            )
        ])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].name, "Родник")
        XCTAssertEqual(points[0].lat, 44.5, accuracy: 1e-6)
    }

    func testANodeWithNoDescriptionIsNotCarried() throws {
        let points = try scan(nodes: [
            (1, 44.5, 33.5, [("natural", "spring"), ("name", "Родник")])
        ])
        XCTAssertTrue(points.isEmpty)
    }

    func testANodeThatIsNotAPlaceOfInterestIsNotCarried() throws {
        let points = try scan(nodes: [
            (1, 44.5, 33.5, [("ref", "42"), ("description", "Просто узел без смысла")])
        ])
        XCTAssertTrue(points.isEmpty)
    }

    func testTheChosenLanguageWinsWhereBothAreThere() throws {
        let points = try scan(nodes: [
            (
                1, 44.5, 33.5,
                [
                    ("tourism", "viewpoint"), ("name", "Вид"),
                    ("description:en", "A wide view over the valley"),
                    ("description:ru", "Широкий вид на долину")
                ]
            )
        ])
        XCTAssertEqual(points.first?.description, "Широкий вид на долину")
    }

    func testAnExcludedObjectIsLeftOut() throws {
        // Whatever is hidden on the map is hidden here too, or the choice is undone by
        // the same objects reappearing under Custom POIs.
        let points = try scan(
            nodes: [
                (
                    1, 44.5, 33.5,
                    [
                        ("amenity", "bench"),
                        ("description", "Скамейка с видом на море")
                    ]
                )
            ],
            exclude: ["amenity=bench"]
        )
        XCTAssertTrue(points.isEmpty)
    }

    func testAWholeKeyCanBeExcluded() throws {
        let points = try scan(
            nodes: [
                (
                    1, 44.5, 33.5,
                    [
                        ("shop", "bakery"),
                        ("description", "Свежий хлеб каждое утро")
                    ]
                )
            ],
            exclude: ["shop=*"]
        )
        XCTAssertTrue(points.isEmpty)
    }

    /// A crescent's box centre lies outside it, in the bay: the point is put on the
    /// crescent itself.
    func testACrescentIsCarriedInsideItself() {
        let crescent: [(lat: Double, lon: Double)] = [
            (0, 0), (0, 10), (10, 10), (10, 0), (8, 0), (8, 8), (2, 8), (2, 0), (0, 0)
        ]
        let inside = MakeGPI.pointInside(crescent)!
        XCTAssertFalse(inside.lat > 2 && inside.lat < 8 && inside.lon < 8, "\(inside) is in the bay")
    }

    /// An outer ring pieced from 2 ways is read in a second look, and carried too.
    func testAMultipolygonWhoseRingIsInPiecesIsCarried() throws {
        let points = try scan(
            nodes: [
                (1, 44.0, 33.0, []), (2, 44.0, 33.02, []),
                (3, 44.02, 33.02, []), (4, 44.02, 33.0, [])
            ],
            ways: [(10, [1, 2, 3], []), (11, [3, 4, 1], [])],
            relations: [
                PBFWriter.Relation(
                    id: 100,
                    members: [.init(kind: 1, ref: 10, role: "outer"), .init(kind: 1, ref: 11, role: "outer")],
                    tags: [
                        ("type", "multipolygon"), ("tourism", "museum"), ("name", "Музей"),
                        ("description", "Краеведческий музей в старой усадьбе")
                    ]
                )
            ]
        )
        XCTAssertEqual(points.map(\.name), ["Музей"])
        XCTAssertEqual(points[0].lat, 44.01, accuracy: 1e-6)
    }

    /// A museum mapped as a multipolygon is carried, at a point inside its outer ring.
    func testAMultipolygonIsCarried() throws {
        let points = try scan(
            nodes: [
                (1, 44.0, 33.0, []), (2, 44.0, 33.02, []),
                (3, 44.02, 33.02, []), (4, 44.02, 33.0, [])
            ],
            ways: [(10, [1, 2, 3, 4, 1], [])],
            relations: [
                PBFWriter.Relation(
                    id: 100,
                    members: [.init(kind: 1, ref: 10, role: "outer")],
                    tags: [
                        ("type", "multipolygon"), ("tourism", "museum"), ("name", "Музей"),
                        ("description", "Краеведческий музей в старой усадьбе")
                    ]
                )
            ]
        )
        XCTAssertEqual(points.map(\.name), ["Музей"])
        XCTAssertEqual(points[0].lat, 44.01, accuracy: 1e-6)
    }

    /// A building round a courtyard: its point is on the building, not in the yard.
    func testAMultipolygonsPointIsNotInItsCourtyard() throws {
        let points = try scan(
            nodes: [
                (1, 44.0, 33.0, []), (2, 44.0, 33.03, []), (3, 44.03, 33.03, []), (4, 44.03, 33.0, []),
                (5, 44.01, 33.01, []), (6, 44.01, 33.02, []), (7, 44.02, 33.02, []), (8, 44.02, 33.01, [])
            ],
            ways: [(10, [1, 2, 3, 4, 1], []), (11, [5, 6, 7, 8, 5], [])],
            relations: [
                PBFWriter.Relation(
                    id: 100,
                    members: [.init(kind: 1, ref: 10, role: "outer"), .init(kind: 1, ref: 11, role: "inner")],
                    tags: [
                        ("type", "multipolygon"), ("tourism", "museum"), ("name", "Музей"),
                        ("description", "Краеведческий музей в старой усадьбе")
                    ]
                )
            ]
        )
        let point = try XCTUnwrap(points.first)
        let inYard = point.lat > 44.01 && point.lat < 44.02 && point.lon > 33.01 && point.lon < 33.02
        XCTAssertFalse(inYard, "\(point)")
        XCTAssertTrue(point.lat > 44.0 && point.lat < 44.03 && point.lon > 33.0 && point.lon < 33.03)
    }

    /// Old-style tagging: the outer way carries the relation's tags too. The relation's
    /// point stands for both, and the way's own, in the yard, is not written.
    func testAnOuterWayTaggedAsItsMultipolygonIsWrittenOnce() throws {
        let tags: [(String, String)] = [
            ("tourism", "museum"), ("name", "Музей"), ("description", "Краеведческий музей в старой усадьбе")
        ]
        let points = try scan(
            nodes: [
                (1, 44.0, 33.0, []), (2, 44.0, 33.03, []), (3, 44.03, 33.03, []), (4, 44.03, 33.0, []),
                (5, 44.01, 33.01, []), (6, 44.01, 33.02, []), (7, 44.02, 33.02, []), (8, 44.02, 33.01, [])
            ],
            ways: [(10, [1, 2, 3, 4, 1], tags), (11, [5, 6, 7, 8, 5], [])],
            relations: [
                PBFWriter.Relation(
                    id: 100,
                    members: [.init(kind: 1, ref: 10, role: "outer"), .init(kind: 1, ref: 11, role: "inner")],
                    tags: [("type", "multipolygon")] + tags
                )
            ]
        )
        XCTAssertEqual(points.count, 1, "\(points)")
        let point = try XCTUnwrap(points.first)
        XCTAssertFalse(point.lat > 44.01 && point.lat < 44.02 && point.lon > 33.01 && point.lon < 33.02, "\(point)")
    }

    /// An unnamed lighthouse is called by the singular, not by the hide list's heading.
    func testAnUnnamedPointIsNamedInTheSingular() {
        XCTAssertEqual(MakeGPI.russianName(key: "man_made", value: "lighthouse"), "Маяк")
        XCTAssertEqual(MakeGPI.russianName(key: "leisure", value: "slipway"), "Спуск для лодок")
    }

    /// The name in the map's own language where OSM has it.
    func testTheNameIsTakenInTheMapsLanguage() throws {
        let tags: [(String, String)] = [
            ("tourism", "viewpoint"), ("name", "Вид"), ("name:en", "View"),
            ("description", "Широкий вид на долину")
        ]
        XCTAssertEqual(try scan(nodes: [(1, 44.5, 33.5, tags)], prefer: "en").first?.name, "View")
        XCTAssertEqual(try scan(nodes: [(1, 44.5, 33.5, tags)], prefer: "ru").first?.name, "Вид")
    }

    func testAnAreaIsCarriedAtTheCentreOfItsBox() throws {
        let points = try scan(
            nodes: [
                (1, 44.0, 33.0, []), (2, 44.0, 33.02, []),
                (3, 44.02, 33.02, []), (4, 44.02, 33.0, [])
            ],
            ways: [
                (
                    10, [1, 2, 3, 4, 1],
                    [
                        ("historic", "ruins"), ("name", "Крепость"),
                        ("description", "Развалины старой крепости")
                    ]
                )
            ]
        )
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].lat, 44.01, accuracy: 1e-6)
        XCTAssertEqual(points[0].lon, 33.01, accuracy: 1e-6)
    }

    func testAnUnnamedObjectIsCalledWhatItIs() throws {
        // So the list under Custom POIs is navigable.
        let points = try scan(nodes: [
            (
                1, 44.5, 33.5,
                [
                    ("man_made", "water_well"),
                    ("description", "Старый колодец, вода солоноватая")
                ]
            )
        ])
        // In the map's language, as the map labels it.
        XCTAssertEqual(points.first?.name, "Колодец")
        // And kinds the map never labels, from the hide list or the GPI's own few.
        XCTAssertEqual(MakeGPI.russianName(key: "natural", value: "spring"), "Родник")
        XCTAssertEqual(MakeGPI.russianName(key: "natural", value: "tree"), "Дерево")
        let english = try scan(
            nodes: [(1, 44.5, 33.5, [("man_made", "water_well"), ("description", "Старый колодец, вода солоноватая")])],
            prefer: "en"
        )
        XCTAssertEqual(english.first?.name, "water well")
    }

    func testManyDescribedObjectsAcrossManyBlocks() throws {
        var nodes: [(id: Int64, lat: Double, lon: Double, tags: [(String, String)])] = []
        for i in Int64(1)...12_000 {
            nodes.append(
                (
                    i, 44 + Double(i) * 1e-5, 33,
                    [
                        ("tourism", "viewpoint"), ("name", "Точка \(i)"),
                        ("description", "Описание с видом номер \(i) на долину")
                    ]
                )
            )
        }
        let points = try scan(nodes: nodes)
        XCTAssertEqual(points.count, 12_000)
    }

    /// A code page kmap cannot write is said before the extract is read: the source here
    /// is not even there.
    func testAnUnknownCodePageIsRefusedBeforeAnythingIsRead() {
        var gpi = MakeGPI(
            source: URL(fileURLWithPath: "/nonexistent/extract.osm.pbf"),
            destination: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("never.gpi")
        )
        gpi.codepage = "cp866"
        XCTAssertThrowsError(try gpi.run()) { error in
            guard case MakeGPI.Trouble.unknownCodePage("cp866") = error else {
                return XCTFail("\(error)")
            }
        }
    }
}
