import XCTest
@testable import kmap

/// kmap's Garmin Custom POI file against gpsbabel's, byte for byte.
///
/// gpsbabel wrote this file until kmap learnt the format itself. Where it is installed it
/// is the reference: the same points must come out as the same bytes, or the device is
/// being handed something it was not handed before. Skipped where it is not installed,
/// which is every machine kmap is shipped to.
final class GPIAgainstGPSBabelTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(gpsbabel != nil, "gpsbabel is not installed")
        work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-gpi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private var gpsbabel: String? {
        ["/opt/homebrew/bin/gpsbabel", "/usr/local/bin/gpsbabel", "/usr/bin/gpsbabel"]
            .first { FileTools.isExecutable($0) } ?? Platform.which("gpsbabel")
    }

    private struct Waypoint {
        let lat: Double, lon: Double, name: String, note: String
    }

    /// What gpsbabel makes of the same points, with the options kmap used to pass.
    ///
    /// - Parameter codePage: the page the text is encoded in. gpsbabel is handed the
    ///   bytes labelled Latin-1, which passes them through untouched, and the page is
    ///   stamped into the result afterwards — which is exactly what kmap used to do.
    private func babelled(_ points: [Waypoint], category: String,
                          codePage: Int = 1252) throws -> Data {
        var gpx = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n"
        gpx += "<gpx version=\"1.1\" creator=\"kmap\""
        gpx += " xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        func encoded(_ text: String) -> String {
            CodePage.latin1(CodePage.encode(text, codePage: codePage, lossy: true) ?? [])
        }
        for point in points {
            gpx += String(format: " <wpt lat=\"%.6f\" lon=\"%.6f\">", point.lat, point.lon)
            gpx += "<name>\(encoded(point.name))</name>"
            gpx += "<desc>\(encoded(point.note))</desc></wpt>\n"
        }
        gpx += "</gpx>\n"
        let source = work.appendingPathComponent("points.gpx")
        try Data(gpx.unicodeScalars.map { UInt8($0.value & 0xFF) }).write(to: source)

        let out = work.appendingPathComponent("babel.gpi")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: try XCTUnwrap(gpsbabel))
        task.arguments = ["-i", "gpx", "-f", source.path,
                          "-o", "garmin_gpi,category=\(encoded(category)),unique=0,hide",
                          "-F", out.path]
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "gpsbabel refused the fixture")

        var made = try Data(contentsOf: out)
        let marker = Data("POI".utf8) + Data([0, 0, 0]) + Data("00".utf8)
        let at = try XCTUnwrap(made.firstRange(of: marker)?.upperBound)
        made[at] = UInt8(codePage & 0xff)
        made[at + 1] = UInt8(codePage >> 8)
        return made
    }

    /// The same points through kmap, stamped with the time gpsbabel stamped its own with.
    private func kmapped(_ points: [Waypoint], category: String, when: Data,
                         codePage: Int = 1252) throws -> Data {
        // The header carries the moment the file was made, which cannot match by luck.
        let stamp = when[16..<20].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        func encoded(_ text: String) -> [UInt8] {
            CodePage.encode(text, codePage: codePage, lossy: true) ?? []
        }
        return GPIFile.data(
            points: points.map {
                GPIFile.Point(lat: $0.lat, lon: $0.lon, name: encoded($0.name),
                              description: encoded($0.note))
            },
            category: encoded(category),
            codePage: codePage,
            fileName: "my.gpi",
            madeAt: GPIFile.epoch.addingTimeInterval(Double(UInt32(littleEndian: stamp))))
    }

    private func check(_ points: [Waypoint], category: String = "kmap",
                       codePage: Int = 1252,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let theirs = try babelled(points, category: category, codePage: codePage)
        let ours = try kmapped(points, category: category, when: theirs, codePage: codePage)
        if ours != theirs {
            let at = zip(ours, theirs).enumerated().first { $0.element.0 != $0.element.1 }?
                .offset
            XCTFail("differs at byte \(at.map(String.init) ?? "the end")"
                    + " — \(ours.count) bytes against \(theirs.count)",
                    file: file, line: line)
        }
    }

    func testOnePoint() throws {
        try check([Waypoint(lat: 45, lon: 34, name: "AB", note: "CD")])
    }

    func testSeveralPointsKeepTheirOrderAndTheirBox() throws {
        try check([Waypoint(lat: 45, lon: 34, name: "AB", note: "CD"),
                   Waypoint(lat: 46, lon: 35, name: "EFG", note: "HIJK"),
                   Waypoint(lat: 44.5, lon: 33.25, name: "third", note: "a longer note")])
    }

    func testTheSouthernAndWesternHemispheres() throws {
        try check([Waypoint(lat: -33.9, lon: 18.4, name: "south", note: "below the line"),
                   Waypoint(lat: 40.7, lon: -74.0, name: "west", note: "left of it"),
                   Waypoint(lat: -41.3, lon: 174.8, name: "far", note: "both at once")])
    }

    func testALongerNameAndNoteThanTheHeaderHasRoomToRound() throws {
        try check([Waypoint(lat: 45.123456, lon: 34.654321,
                            name: String(repeating: "n", count: 60),
                            note: String(repeating: "d", count: 200))])
    }

    func testTheyComeOutInNameOrderWhateverOrderTheyWentIn() throws {
        // A device lists them by name, and the file is written that way; the bytes of
        // the code page decide, not the letters.
        try check([Waypoint(lat: 1, lon: 1, name: "apple", note: "one one"),
                   Waypoint(lat: 2, lon: 2, name: "Banana", note: "two two"),
                   Waypoint(lat: 3, lon: 3, name: "_under", note: "three three"),
                   Waypoint(lat: 4, lon: 4, name: "apple", note: "four four")])
    }

    func testACategoryOfItsOwn() throws {
        try check([Waypoint(lat: 45, lon: 34, name: "AB", note: "CD")],
                  category: "kmap points")
    }

    func testEnoughPointsToBeCutIntoGroups() throws {
        // Past 128 points the writer cuts them into a tree of boxes so a device can skip
        // a whole box at once. This is the only case that exercises it, and the shape of
        // that tree has to be the shape gpsbabel made.
        //
        // Coordinates land on the grid the fixture's own text format can carry, so both
        // sides see the same numbers rather than two roundings of one.
        var seed: UInt64 = 0x5eed
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 11) % 1_000_000) / 1_000_000
        }
        var points: [Waypoint] = []
        for i in 0..<1500 {
            // Two clusters, so the tree is not a regular grid.
            let base = i % 3 == 0 ? (44.0, 33.0) : (46.5, 35.5)
            points.append(Waypoint(lat: base.0 + next(), lon: base.1 + next(),
                                   name: "point \(i)", note: "note for point \(i)"))
        }
        try check(points)
    }

    func testCyrillicInTheCodePageARussianMapIsBuiltWith() throws {
        try check([Waypoint(lat: 44.5, lon: 34.1, name: "Родник",
                            note: "Вода круглый год, слева от тропы"),
                   Waypoint(lat: 44.6, lon: 34.2, name: "Стоянка",
                            note: "Ровное место на четыре палатки")],
                  // An ASCII category: gpsbabel takes it as a command-line argument,
                  // which cannot carry code-page bytes the way the file can.
                  category: "kmap", codePage: 1251)
    }

    func testALetterTheCodePageHasNoRoomForBecomesAQuestionMarkInBoth() throws {
        // Lossy on purpose: one letter must not cost the whole point.
        try check([Waypoint(lat: 45, lon: 34, name: "Grüße 東京", note: "mixed scripts")],
                  codePage: 1251)
    }
}
