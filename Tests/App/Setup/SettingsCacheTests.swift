import XCTest

@testable import kmap

/// A cache is not emptied under a build or a download another kmap is running.
@MainActor
final class SettingsCacheTests: XCTestCase {
    func testAHeldBuildOrDownloadLockKeepsTheCache() async throws {
        let locks = FileManager.default.temporaryDirectory.appendingPathComponent("locks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: locks) }
        XCTAssertFalse(SettingsScreen.buildOrDownloadRunning(in: locks))

        // Left behind by runs that ended: no one holds them.
        for name in ["work-old.lock", "download-pbf-x.lock", "tools-in-use.lock"] {
            try FileTools.write("", to: locks.appendingPathComponent(name))
        }
        XCTAssertFalse(SettingsScreen.buildOrDownloadRunning(in: locks))

        for name in ["work-old.lock", "download-pbf-x.lock"] {
            var held = HeldLock(trying: locks.appendingPathComponent(name))
            XCTAssertEqual(held?.isHeld, true)
            XCTAssertTrue(SettingsScreen.buildOrDownloadRunning(in: locks), name)
            held = nil
            XCTAssertFalse(SettingsScreen.buildOrDownloadRunning(in: locks), name)
        }
    }

    private func folder(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileTools.write(text, to: url)
    }

    private func clear(_ cache: URL, elevation: Bool) -> (asked: Int64, gone: (files: Int, bytes: Int64)) {
        let asked = CacheClearing.preview(cache, elevation: elevation).bytes
        return (asked, CacheClearing.clear(cache, elevation: elevation))
    }

    /// The names kmap writes, where it writes them, and only those.
    func testOnlyKmapsOwnNamesAreItsOwn() async {
        let own: [(CacheFolderKind, [String])] = [
            (.elevationTop, ["viewfinderHgtIndex_1.txt", "hgtIndex_1_v3.0.txt"]),
            (
                .source,
                [
                    "N54E019.hgt", "S01W123.hgt", "N54E019.tif", "N54E019.v1.2.sea", "N54E019.sea", "N54E019.v1.2.out",
                    "N54E019.hgt.1a2b3c4d.part"
                ]
            ),
            (
                .viewfinder,
                [
                    "N54E019.hgt", "download-1a2b3c4d.zip", "download-1a2b3c4d.zip.part0",
                    "download-1a2b3c4d.zip.layout", "unpack-1a2b3c4d"
                ]
            ),
            (.tifs, ["N54E019.tif", "N54E019.assembling", "N54E019.assembling.part0", "N54E019.assembling.layout"]),
            (.chunks, ["0-100.deflate", "0-9000.deflate.part0", "12-3.deflate.layout"]),
            (
                .extracts,
                [
                    "andorra.osm.pbf", "andorra.osm.pbf.stamp", "austria.osm.pbf.layout", "austria.osm.pbf.part0",
                    "russia.osm.pbf.new.part3", "russia.osm.pbf.new.layout", "monaco.osm.pbf.suspect",
                    "monaco.osm.pbf.stamp.suspect"
                ]
            )
        ]
        let other: [(CacheFolderKind, [String])] = [
            (.elevationTop, ["N54E019.hgt", "notes.txt"]),
            (
                .source,
                [
                    "download-receipt.pdf", "report.hgt.bak", "Installer.sea", "._N54E019.hgt", "N54E019.hgt.bak",
                    "unpack-2026", "photo.jpg", "N5E019.hgt", "X54E019.hgt", "n54e019.hgt",
                    "download-1a2b3c4d.zip.notes.txt", "0-100.deflate", "download-1a2b3c4d.zip", "unpack-1a2b3c4d"
                ]
            ),
            (.viewfinder, ["download-1a2b3c4d.zipper", "download-1a2b3c4d.zip.bak", "unpack-2026"]),
            (.tifs, ["N05E005.hgt", "download-1a2b3c4d.zip", "1-2.deflate", "N54E019.assembling.notes"]),
            (.chunks, ["N07E007.tif", "1-2-3.deflate", "-1.deflate", "1-2.DEFLATE", "1-2.deflate.part"]),
            (
                .extracts,
                [
                    "my.osm.pbf.backup", ".osm.pbf", "._x.osm.pbf", "x.osm.pbfx", "map.osm.pbf~",
                    "x.osm.pbf.part\u{FF11}", "notes.txt", "x.osm.pbf.partial"
                ]
            )
        ]
        for (kind, names) in own {
            for name in names { XCTAssertTrue(CacheClearing.isOwn(name, in: kind), "\(kind) \(name)") }
        }
        for (kind, names) in other {
            for name in names { XCTAssertFalse(CacheClearing.isOwn(name, in: kind), "\(kind) \(name)") }
        }
    }

    /// The usual layout clears whole, and the question says what goes.
    func testTheUsualCacheClearsWhole() async throws {
        let hgt = try folder("hgt").appendingPathComponent("hgt")
        var bytes: Int64 = 0
        for (source, name) in [
            ("COP1", "N42E001.hgt"), ("COP3", "N42E001.hgt"), ("FAB1", "N43E007.hgt"), ("GED1", "N40E008.hgt"),
            ("GED1", "N40E009.v1.2.sea"), ("VIEW1", "N41E045.hgt"), ("VIEW3", "N40E036.hgt"), ("SRTM1", "N40E037.tif"),
            ("VIEW1", "unpack-1a2b3c4d/N41E046.hgt"), ("VIEW1", "unpack-1a2b3c4d/.keep"),
            ("VIEW1", "unpack-1a2b3c4d/.zone/N41E047.hgt")
        ] {
            try write("1234", hgt.appendingPathComponent("\(source)/\(name)"))
            bytes += 4
        }
        try write("12", hgt.appendingPathComponent("viewfinderHgtIndex_1.txt"))
        bytes += 2
        let (asked, gone) = clear(hgt, elevation: true)
        XCTAssertEqual(asked, bytes)
        XCTAssertEqual(gone.files, 6)
        XCTAssertEqual(gone.bytes, bytes)
        XCTAssertTrue(FileTools.filesThroughLinks(under: hgt, extension: "hgt").isEmpty)
        XCTAssertTrue(FileTools.allFiles(under: hgt, hidden: true).isEmpty)
        XCTAssertEqual(CacheClearing.preview(hgt, elevation: true).bytes, 0)
    }

    /// The Settings row counts what a clear deletes; a link back to the cache is no source.
    func testTheRowCountsWhatTheClearDeletes() async throws {
        let root = try folder("cache")
        let hgt = root.appendingPathComponent("hgt")
        for (source, name) in [("COP1", "N42E001.hgt"), ("VIEW3", "N40E036.hgt"), ("GED1", "N40E009.v1.2.sea")] {
            try write("1234", hgt.appendingPathComponent("\(source)/\(name)"))
        }
        try write("12", root.appendingPathComponent("copernicus-tif/N02E002.tif"))
        #if !os(Windows)
        try FileManager.default.createSymbolicLink(at: hgt.appendingPathComponent("FAB1"), withDestinationURL: hgt)
        #endif
        let row = AppContext.Overview.Elevation.sample(hgt)
        let asked = CacheClearing.preview(hgt, elevation: true)
        XCTAssertEqual(row.tiles, asked.files)
        XCTAssertEqual(row.bytes, asked.bytes)
        XCTAssertEqual(row.sources, ["COP1", "VIEW3"])
        let gone = CacheClearing.clear(hgt, elevation: true)
        XCTAssertEqual(gone.files, row.tiles)
        XCTAssertEqual(gone.bytes, row.bytes)
    }

    /// A source folder in another case is cleared where the disk ignores case.
    func testASourceFolderInAnotherCase() async throws {
        let hgt = try folder("hgt").appendingPathComponent("hgt")
        try write("12", hgt.appendingPathComponent("cop1/N01E001.hgt"))
        let ignoresCase = FileTools.isDirectory(hgt.appendingPathComponent("COP1"))
        let gone = CacheClearing.clear(hgt, elevation: true)
        XCTAssertEqual(gone.files, ignoresCase ? 1 : 0)
        XCTAssertEqual(FileTools.exists(hgt.appendingPathComponent("cop1/N01E001.hgt")), !ignoresCase)
    }

    /// Extracts go with their stamps, parts and kept stamps; anything else stays.
    func testTheExtractCacheLosesItsExtracts() async throws {
        let pbf = try folder("cache").appendingPathComponent("pbf")
        try write("12345", pbf.appendingPathComponent("a.osm.pbf"))
        try write("1", pbf.appendingPathComponent("a.osm.pbf.stamp"))
        try write("12", pbf.appendingPathComponent("b.osm.pbf.part0"))
        try write("123", pbf.appendingPathComponent("c.osm.pbf.stamp.suspect"))
        let kept = ["planet-latest.osm.pbf", "my.osm.pbf.backup", "x.osm.pbfx", "notes.txt", "old/2019/france.osm.pbf"]
        for name in kept { try write("keep", pbf.appendingPathComponent(name)) }
        let (asked, gone) = clear(pbf, elevation: false)
        XCTAssertEqual(asked, 11)
        XCTAssertEqual(gone.files, 1)
        XCTAssertEqual(gone.bytes, 11)
        XCTAssertEqual(
            FileTools.contents(of: pbf).map(\.lastPathComponent),
            ["my.osm.pbf.backup", "notes.txt", "old", "planet-latest.osm.pbf", "x.osm.pbfx"]
        )
        XCTAssertTrue(FileTools.exists(pbf.appendingPathComponent("old/2019/france.osm.pbf")))
    }

    /// A bare extract under a region's name from the Geofabrik index is kmap's; another stays.
    func testABareExtractOfAKnownRegionGoes() async throws {
        let root = try folder("cache")
        let pbf = root.appendingPathComponent("pbf")
        let index = root.appendingPathComponent("geofabrik-index.json")
        try write(#"{"features":[{"properties":{"id":"central-fed-district","name":"Central"}}]}"#, index)
        try write("12345", pbf.appendingPathComponent("central-fed-district.osm.pbf"))
        try write("keep", pbf.appendingPathComponent("france.osm.pbf"))
        XCTAssertEqual(CacheClearing.preview(pbf, elevation: false, index: index).files, 1)
        let none = root.appendingPathComponent("none.json")
        XCTAssertEqual(CacheClearing.preview(pbf, elevation: false, index: none).files, 0, "no index, no region names")
        let gone = CacheClearing.clear(pbf, elevation: false, index: index)
        XCTAssertEqual(gone.files, 1)
        XCTAssertEqual(gone.bytes, 5)
        XCTAssertEqual(FileTools.contents(of: pbf).map(\.lastPathComponent), ["france.osm.pbf"])
    }

    /// GeoTIFFs and chunks beside the tiles go too, by the names kmap gives them.
    func testDownloadsBesideTheTilesGoToo() async throws {
        let root = try folder("cache")
        let hgt = root.appendingPathComponent("hgt")
        try write("12", hgt.appendingPathComponent("COP1/N01E001.hgt"))
        let tifs = root.appendingPathComponent("copernicus-tif")
        let chunks = root.appendingPathComponent(GEDTM30.v12.chunkDirectory.lastPathComponent)
        try write("1234", tifs.appendingPathComponent("N02E002.tif"))
        try write("12", tifs.appendingPathComponent("N03E003.assembling.part0"))
        try write("123", chunks.appendingPathComponent("0-100.deflate"))
        try write("1", chunks.appendingPathComponent("0-9000.deflate.part0"))
        for kept in ["keep.txt", "N05E005.hgt", "1-2.deflate"] { try write("keep", tifs.appendingPathComponent(kept)) }
        try write("keep", chunks.appendingPathComponent("N07E007.tif"))
        let (asked, gone) = clear(hgt, elevation: true)
        XCTAssertEqual(asked, 12)
        XCTAssertEqual(gone.files, 1)
        XCTAssertEqual(gone.bytes, 12)
        XCTAssertEqual(
            FileTools.contents(of: tifs).map(\.lastPathComponent),
            ["1-2.deflate", "N05E005.hgt", "keep.txt"]
        )
        XCTAssertEqual(FileTools.contents(of: chunks).map(\.lastPathComponent), ["N07E007.tif"])
        XCTAssertFalse(CacheClearing.preview(hgt, elevation: true).any)
    }

    #if !os(Windows)
    /// Through a link, a bare extract goes only with its stamp.
    func testALinkedExtractCacheKeepsUnstampedExtracts() async throws {
        let root = try folder("cache")
        let downloads = root.appendingPathComponent("Downloads")
        try write("12345", downloads.appendingPathComponent("a.osm.pbf"))
        try write("1", downloads.appendingPathComponent("a.osm.pbf.stamp"))
        try write("keep", downloads.appendingPathComponent("planet-latest.osm.pbf"))
        let cache = root.appendingPathComponent("pbf")
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: downloads)
        let (asked, gone) = clear(cache, elevation: false)
        XCTAssertEqual(asked, 6)
        XCTAssertEqual(gone.files, 1)
        XCTAssertEqual(FileTools.contents(of: downloads).map(\.lastPathComponent), ["planet-latest.osm.pbf"])
    }

    /// A linked source loses its tiles alone. Links to the cache or above it, dangling links
    /// and linked staging are left.
    func testALinkedSourceLosesOnlyItsTiles() async throws {
        let root = try folder("hgt")
        let kmap = root.appendingPathComponent("kmap")
        let hgt = kmap.appendingPathComponent("hgt")
        let disk = root.appendingPathComponent("disk")
        for (source, name) in [("COP3", "N42E001.hgt"), ("FAB1", "N43E007.hgt"), ("GED1", "N40E008.hgt")] {
            try write("12", hgt.appendingPathComponent("\(source)/\(name)"))
        }
        try write("1234", disk.appendingPathComponent("N02E002.hgt"))
        let kept = [
            "photo.jpg", "Documents/thesis.txt", "GIS/mydem/N03E003.hgt", "Docs/download-2026.pdf", "report.hgt.bak",
            ".hidden/N04E004.hgt", "download-receipt.pdf", "mine/N07E007.hgt"
        ]
        for name in kept { try write("keep", disk.appendingPathComponent(name)) }
        try write("{}", kmap.appendingPathComponent("settings.json"))
        try write("keep", kmap.appendingPathComponent("N05E005.hgt"))
        try write("keep", hgt.appendingPathComponent("N06E006.hgt"))
        try FileManager.default.createSymbolicLink(
            at: hgt.appendingPathComponent("FAB1/unpack-1a2b3c4d"),
            withDestinationURL: disk.appendingPathComponent("mine")
        )
        for (link, target) in [
            ("COP1", disk), ("SRTM1", disk), ("SRTM3", kmap), ("ALOS1", hgt), ("UP", kmap),
            ("VIEW1", root.appendingPathComponent("unplugged"))
        ] {
            try FileManager.default.createSymbolicLink(at: hgt.appendingPathComponent(link), withDestinationURL: target)
        }
        XCTAssertEqual(CacheClearing.folders(hgt, elevation: true).filter { $0.kind == .source }.count, 4)

        let (asked, gone) = clear(hgt, elevation: true)
        XCTAssertEqual(asked, 10)
        XCTAssertEqual(gone.files, 4)
        XCTAssertEqual(gone.bytes, 10)
        for link in ["COP1", "SRTM1", "SRTM3", "ALOS1", "UP", "VIEW1", "FAB1/unpack-1a2b3c4d"] {
            XCTAssertEqual(FileTools.type(of: hgt.appendingPathComponent(link)), .typeSymbolicLink, link)
        }
        XCTAssertFalse(FileTools.exists(disk.appendingPathComponent("N02E002.hgt")))
        for name in kept { XCTAssertTrue(FileTools.exists(disk.appendingPathComponent(name)), name) }
        XCTAssertTrue(FileTools.exists(kmap.appendingPathComponent("settings.json")))
        XCTAssertTrue(FileTools.exists(kmap.appendingPathComponent("N05E005.hgt")))
        XCTAssertTrue(FileTools.exists(hgt.appendingPathComponent("N06E006.hgt")))
        XCTAssertEqual(CacheClearing.preview(hgt, elevation: true).bytes, 0)
    }

    /// A cache linked to a home folder keeps the person's tiles.
    func testACacheLinkedToAHomeFolderKeepsThePersonsTiles() async throws {
        let root = try folder("hgt")
        let home = root.appendingPathComponent("home")
        let kept = ["N48E009.hgt", "Downloads/N47E008.hgt", "Downloads/N47E008.tif", ".hidden/N01E001.hgt", "photo.jpg"]
        for name in kept { try write("keep", home.appendingPathComponent(name)) }
        try write("12", home.appendingPathComponent("COP1/N02E002.hgt"))
        try write("1", home.appendingPathComponent("viewfinderHgtIndex_3.txt"))
        let cache = root.appendingPathComponent("hgt")
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: home)

        let gone = CacheClearing.clear(cache, elevation: true)
        XCTAssertEqual(gone.files, 1)
        for name in kept { XCTAssertTrue(FileTools.exists(home.appendingPathComponent(name)), name) }
        XCTAssertFalse(FileTools.exists(home.appendingPathComponent("COP1/N02E002.hgt")))
        XCTAssertFalse(FileTools.exists(home.appendingPathComponent("viewfinderHgtIndex_3.txt")))
        XCTAssertTrue(FileTools.isDirectory(cache))
    }

    /// What will not go is not said to have gone.
    func testWhatStaysIsNotCounted() async throws {
        try XCTSkipIf(getuid() == 0, "root deletes in a read-only folder")
        let hgt = try folder("hgt").appendingPathComponent("hgt")
        let fab = hgt.appendingPathComponent("FAB1")
        try write("12", fab.appendingPathComponent("N01E001.hgt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fab.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fab.path) }
        let gone = CacheClearing.clear(hgt, elevation: true)
        XCTAssertTrue(FileTools.exists(fab.appendingPathComponent("N01E001.hgt")))
        XCTAssertEqual(gone.files, 0)
    }
    #endif

    #if os(Windows)
    /// Junctions lead only to kmap's files: behind a source, a cache or a staging folder.
    func testJunctionsLeadOnlyToKmapsFiles() async throws {
        func junction(_ link: URL, _ target: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
            process.arguments = ["/c", "mklink", "/J", link.nativePath, target.nativePath]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try XCTSkipUnless(process.terminationStatus == 0, "mklink /J failed")
        }
        let root = try folder("hgt")
        let disk = root.appendingPathComponent("disk")
        let home = root.appendingPathComponent("home")
        try write("1234", disk.appendingPathComponent("N02E002.hgt"))
        try write("keep", disk.appendingPathComponent("photo.jpg"))
        try write("keep", disk.appendingPathComponent("mine/N03E003.hgt"))
        try write("keep", home.appendingPathComponent("N48E009.hgt"))
        try write("keep", home.appendingPathComponent("notes.txt"))
        let hgt = root.appendingPathComponent("kmap/hgt")
        try write("12", hgt.appendingPathComponent("FAB1/N01E001.hgt"))
        try junction(hgt.appendingPathComponent("COP1"), disk)
        try junction(hgt.appendingPathComponent("FAB1/unpack-1a2b3c4d"), disk.appendingPathComponent("mine"))

        let gone = CacheClearing.clear(hgt, elevation: true)
        XCTAssertEqual(gone.files, 2)
        XCTAssertFalse(FileTools.exists(disk.appendingPathComponent("N02E002.hgt")))
        XCTAssertTrue(FileTools.exists(disk.appendingPathComponent("photo.jpg")))
        XCTAssertTrue(FileTools.exists(disk.appendingPathComponent("mine/N03E003.hgt")))

        let cache = root.appendingPathComponent("pbf")
        try write("12345", home.appendingPathComponent("a.osm.pbf"))
        try write("keep", home.appendingPathComponent("planet-latest.osm.pbf"))
        try write("1", home.appendingPathComponent("a.osm.pbf.stamp"))
        try junction(cache, home)
        _ = CacheClearing.clear(cache, elevation: false)
        XCTAssertEqual(
            FileTools.contents(of: home).map(\.lastPathComponent),
            ["N48E009.hgt", "notes.txt", "planet-latest.osm.pbf"]
        )
    }
    #endif
}
