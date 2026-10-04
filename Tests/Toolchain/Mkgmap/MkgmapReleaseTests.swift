import XCTest

@testable import kmap

/// The mkgmap downloads kmap runs and compiles are taken only with the SHA-256 it knows.
final class MkgmapReleaseTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheFileWithTheKnownChecksumIsTaken() throws {
        let file = directory.appendingPathComponent("abc.zip")
        try Data("abc".utf8).write(to: file)
        let pinned = Toolchain.PinnedDownload(
            file: "abc.zip",
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertNoThrow(try Toolchain.verify(file, against: pinned))
    }

    func testAnyOtherFileIsRefused() throws {
        let file = directory.appendingPathComponent("abc.zip")
        try Data("abd".utf8).write(to: file)
        let pinned = Toolchain.PinnedDownload(
            file: "abc.zip",
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertThrowsError(try Toolchain.verify(file, against: pinned))
        XCTAssertThrowsError(try Toolchain.verify(directory.appendingPathComponent("absent.zip"), against: pinned))
    }

    func testThePatchedSourceIsTheInstalledRelease() {
        // The patch is built from the source of the release kmap installs.
        let revision = Toolchain.mkgmapRelease.file.allMatches("[0-9]+").first
        XCTAssertNotNil(revision.flatMap { Toolchain.mkgmapSources[$0] })
    }
}
