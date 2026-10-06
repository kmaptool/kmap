import XCTest

@testable import kmap

/// A kmap that waited on another one's install of a pack takes that install, and fetches
/// nothing.
final class DataPackFetchTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("packs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.folder) }
    }

    /// Installed and stamped, with the lock on its update held by "another kmap" that
    /// `restamp` stands for and then lets go.
    private func waitingOnAnother(restamp: (DataPack) throws -> Void) async throws {
        let file = folder.appendingPathComponent("pack.zip")
        try FileTools.write(Data(repeating: 0, count: 2_000_000), to: file)
        let pack = DataPack(
            id: "test",
            url: URL(string: "https://example.invalid/pack.zip")!,
            file: file,
            what: "test pack"
        )
        CacheStamp(size: 2_000_000, lastModified: "Fri, 04 Sep 2026 12:27:24 GMT", md5: nil).write(besides: file)
        Paths.ensure(Paths.locks)
        var other = HeldLock(trying: Downloader.lockFile(for: file.appendingPathExtension(DataPack.stagingSuffix)))
        XCTAssertNotNil(other)

        let fetch = Task { try await pack.fetch(using: Downloader(log: Log())) }
        try await Task.sleep(nanoseconds: 300_000_000)
        try restamp(pack)
        other = nil
        try await fetch.value
    }

    func testANewStampIsTheInstallItWaitedFor() async throws {
        try await waitingOnAnother { pack in
            CacheStamp(size: 2_000_000, lastModified: "Sat, 05 Sep 2026 08:00:00 GMT", md5: nil)
                .write(besides: pack.file)
        }
    }

    /// The same pack again writes the same stamp; its file's time still moves.
    func testTheSameStampWrittenAgainIsTooTheInstall() async throws {
        try await waitingOnAnother { pack in
            let stamp = CacheStamp.url(for: pack.file)
            let text = try Data(contentsOf: stamp)
            try FileTools.write(text, to: stamp)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(10)],
                ofItemAtPath: stamp.path
            )
        }
    }

    /// A stamp dated ahead of the clock, with no other kmap at work, is no install that
    /// was waited for: the pack is fetched (and here fails, the host not existing).
    func testAStampAheadOfTheClockIsNotTakenForAnotherInstall() async throws {
        let file = folder.appendingPathComponent("pack.zip")
        try FileTools.write(Data(repeating: 0, count: 2_000_000), to: file)
        let pack = DataPack(
            id: "test",
            url: URL(string: "https://example.invalid/pack.zip")!,
            file: file,
            what: "test pack"
        )
        CacheStamp(size: 2_000_000, lastModified: nil, md5: nil).write(besides: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: CacheStamp.url(for: file).path
        )
        do {
            try await pack.fetch(using: Downloader(log: Log()))
            XCTFail("the pack was taken as fetched")
        } catch {}
    }
}
