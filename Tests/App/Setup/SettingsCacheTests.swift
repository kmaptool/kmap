import XCTest

@testable import kmap

/// A cache is not emptied under a build or a download another kmap is running.
@MainActor
final class SettingsCacheTests: XCTestCase {
    func testAHeldBuildOrDownloadLockKeepsTheCache() throws {
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

    /// The files go aside at once and an empty folder takes their place, through a link
    /// to the cache too: a build started while they are deleted finds none.
    func testClearingSetsTheFilesAsideFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
        let real = root.appendingPathComponent("pbf")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileTools.write("12345", to: real.appendingPathComponent("a.osm.pbf"))
        #if os(Windows)
        // A link there needs a right a test run may not have.
        let cache = real
        #else
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let cache = link
        #endif

        XCTAssertEqual(SettingsScreen.emptied(cache, elevation: false).count, 1)
        let plan = SettingsScreen.setAside(cache, elevation: false)
        XCTAssertEqual(plan.aside.count, 1)
        XCTAssertTrue(plan.inPlace.isEmpty)
        XCTAssertTrue(FileTools.contents(of: cache).isEmpty)
        XCTAssertEqual(FileTools.contents(of: plan.aside[0]).map(\.lastPathComponent), ["a.osm.pbf"])
        XCTAssertTrue(SettingsScreen.clear(plan, elevation: false).contains("5"))
        XCTAssertFalse(FileTools.exists(plan.aside[0]))
        XCTAssertTrue(FileTools.exists(real))
    }

    #if !os(Windows)
    /// A source's tiles linked from another disk keep their link, and are counted, in the
    /// question too, and deleted; a folder named like ours that is not one is left. In the
    /// extract cache a linked folder is the person's own and stays whole.
    func testALinkedSourceKeepsItsLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hgt-\(UUID().uuidString)")
        let hgt = root.appendingPathComponent("hgt")
        let disk = root.appendingPathComponent("disk/COP1")
        let mine = root.appendingPathComponent(".hgt-clearing-mine")
        for dir in [hgt.appendingPathComponent("FAB1"), disk, mine] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileTools.write("12", to: hgt.appendingPathComponent("FAB1/N01E001.hgt"))
        try FileTools.write("1234", to: disk.appendingPathComponent("N02E002.hgt"))
        try FileManager.default.createSymbolicLink(at: hgt.appendingPathComponent("COP1"), withDestinationURL: disk)

        let asked = SettingsScreen.emptied(hgt, elevation: true).map { SettingsScreen.tally($0, elevation: true) }
        XCTAssertEqual(asked.reduce(0) { $0 + $1.bytes }, 6)
        let plan = SettingsScreen.setAside(hgt, elevation: true)
        XCTAssertEqual(plan.aside.count, 2)
        let said = SettingsScreen.clear(plan, elevation: true)
        XCTAssertTrue(said.contains("2"), said)
        XCTAssertTrue(said.contains("6"), said)
        XCTAssertTrue(FileTools.isDirectory(hgt.appendingPathComponent("COP1")))
        XCTAssertFalse(FileTools.isDirectoryItself(hgt.appendingPathComponent("COP1")), "still a link")
        XCTAssertTrue(FileTools.contents(of: disk).isEmpty)
        XCTAssertFalse(FileTools.exists(hgt.appendingPathComponent("FAB1")))
        XCTAssertTrue(FileTools.exists(mine))
        for aside in plan.aside { XCTAssertFalse(FileTools.exists(aside)) }

        let pbf = root.appendingPathComponent("pbf")
        let kept = root.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: pbf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileTools.write("1", to: kept.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: pbf.appendingPathComponent("mine"), withDestinationURL: kept)
        _ = SettingsScreen.clear(SettingsScreen.setAside(pbf, elevation: false), elevation: false)
        XCTAssertTrue(FileTools.exists(kept.appendingPathComponent("keep.txt")))
        XCTAssertTrue(FileTools.isDirectory(pbf.appendingPathComponent("mine")))
    }

    /// Emptied in place where it cannot be renamed: a link inside stays, its folder emptied.
    func testInPlaceTheLinkStays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hgt-\(UUID().uuidString)")
        let hgt = root.appendingPathComponent("hgt")
        let disk = root.appendingPathComponent("disk")
        try FileManager.default.createDirectory(at: hgt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileTools.write("12", to: hgt.appendingPathComponent("N01E001.hgt"))
        try FileTools.write("1234", to: disk.appendingPathComponent("N02E002.hgt"))
        try FileManager.default.createSymbolicLink(at: hgt.appendingPathComponent("COP1"), withDestinationURL: disk)

        let said = SettingsScreen.clear(([], [hgt, disk]), elevation: true)
        XCTAssertTrue(said.contains("2"), said)
        XCTAssertFalse(FileTools.exists(hgt.appendingPathComponent("N01E001.hgt")))
        XCTAssertFalse(FileTools.exists(disk.appendingPathComponent("N02E002.hgt")))
        XCTAssertTrue(FileTools.isDirectory(hgt.appendingPathComponent("COP1")))
    }

    /// The elevation cache linked whole to another folder: its linked sources are still
    /// found, each once, and one inside the cache is not counted twice.
    func testACacheThatIsALinkStillFindsItsSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hgt-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        let disk = root.appendingPathComponent("disk")
        for dir in [real.appendingPathComponent("FAB1"), disk] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileTools.write("12", to: real.appendingPathComponent("FAB1/N01E001.hgt"))
        try FileTools.write("1234", to: disk.appendingPathComponent("N02E002.hgt"))
        let cache = root.appendingPathComponent("hgt")
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: real)
        for name in ["COP1", "COP3"] {
            try FileManager.default.createSymbolicLink(at: real.appendingPathComponent(name), withDestinationURL: disk)
        }
        try FileManager.default.createSymbolicLink(
            at: real.appendingPathComponent("FAB3"),
            withDestinationURL: real.appendingPathComponent("FAB1")
        )

        let emptied = SettingsScreen.emptied(cache, elevation: true)
        XCTAssertEqual(emptied.count, 2, "\(emptied)")
        XCTAssertEqual(emptied.reduce(Int64(0)) { $0 + SettingsScreen.tally($1, elevation: true).bytes }, 6)
        let said = SettingsScreen.clear(SettingsScreen.setAside(cache, elevation: true), elevation: true)
        XCTAssertTrue(said.contains("2"), said)
        XCTAssertTrue(FileTools.contents(of: disk).isEmpty)
        XCTAssertTrue(FileTools.isDirectory(real.appendingPathComponent("COP1")))
    }

    /// What will not go is not said to have gone.
    func testWhatStaysIsNotCounted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hgt-\(UUID().uuidString)")
        let hgt = root.appendingPathComponent("hgt/FAB1")
        try FileManager.default.createDirectory(at: hgt, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hgt.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileTools.write("12", to: hgt.appendingPathComponent("N01E001.hgt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hgt.path)
        let said = SettingsScreen.clear(([], [root.appendingPathComponent("hgt")]), elevation: true)
        XCTAssertTrue(FileTools.exists(hgt.appendingPathComponent("N01E001.hgt")))
        XCTAssertTrue(said.contains("0"), said)
    }
    #endif
}
