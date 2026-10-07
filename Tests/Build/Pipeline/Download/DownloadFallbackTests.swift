#if !os(Windows)
import XCTest

@testable import kmap

/// A failed download falls back on a stale copy, never on a damaged one or one put back
/// during the fetch.
final class DownloadFallbackTests: XCTestCase {
    private static let modified = "Tue, 06 Oct 2026 20:00:00 GMT"
    private var server: LoopbackServer!
    private let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    private let failing = Locked(false)
    private let headFails = Locked(false)
    /// Run once as the first extract request arrives: what another kmap does meanwhile.
    private let meanwhile = Locked<(@Sendable () -> Void)?>(nil)
    private let region = "test/fallback-\(UUID().uuidString.prefix(8))"

    private var extract: URL { Paths.cachedExtract(forRegion: region) }

    override func setUpWithError() throws {
        let body = body
        let md5 = Data(MD5.hex(of: body).utf8 + Array("  extract.osm.pbf\n".utf8))
        let (failing, meanwhile, headFails) = (failing, meanwhile, headFails)
        server = try LoopbackServer { request in
            let file = request.path.hasSuffix(".md5") ? md5 : body
            var headers = [
                ("Content-Length", "\(file.count)"), ("Last-Modified", Self.modified), ("Accept-Ranges", "bytes")
            ]
            if request.method == "HEAD" {
                if request.path.hasSuffix(".pbf"), headFails.withLock({ $0 }) {
                    return .init(status: 404, headers: [("Content-Length", "0")])
                }
                return .init(status: 200, headers: headers)
            }
            if request.path.hasSuffix(".pbf") {
                meanwhile.withLock { hook in
                    hook?()
                    hook = nil
                }
                if failing.withLock({ $0 }) { return .init(status: 404, headers: [("Content-Length", "0")]) }
            }
            guard let range = request.header("Range"), let dash = range.firstIndex(of: "-"),
                let from = Int(range.dropFirst("bytes=".count).prefix(upTo: dash))
            else { return .init(status: 200, headers: headers, body: file) }
            let to = Int(range[range.index(after: dash)...]) ?? file.count - 1
            let slice = file.subdata(in: from..<min(to + 1, file.count))
            headers[0] = ("Content-Length", "\(slice.count)")
            headers.append(("Content-Range", "bytes \(from)-\(from + slice.count - 1)/\(file.count)"))
            return .init(status: 206, headers: headers, body: slice)
        }
        addTeardownBlock { [extract] in
            for url in [extract, CacheStamp.url(for: extract), extract.appendingPathExtension("suspect")] {
                FileTools.removeIfPresent(url)
            }
            FileTools.removeIfPresent(BuildPipeline.keptStamp(besides: extract))
        }
    }

    override func tearDown() {
        server?.stop()
    }

    private func pipeline() -> BuildPipeline {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let place = Region(
            id: region,
            name: "Fallback",
            parentID: nil,
            pbfURL: server.url("/extract-latest.osm.pbf"),
            bbox: .empty,
            boxes: []
        )
        let style = MapStyle(
            id: "plain",
            name: "Plain",
            summary: "",
            origin: .builtin,
            styleDirectory: nil,
            typURL: nil,
            familyID: 6300,
            productID: 1
        )
        return BuildPipeline(
            recipe: BuildRecipe(region: place, style: style, outputDirectory: Paths.root.appendingPathComponent("out")),
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain)
        )
    }

    /// Fetched whole, then the given bytes and stamp in its place.
    private func cached(_ bytes: Data, stamp: CacheStamp) async throws {
        let fetched = try await pipeline().downloadExtracts()
        XCTAssertEqual(fetched, [extract])
        XCTAssertEqual(try Data(contentsOf: extract), body)
        try FileTools.write(bytes, to: extract)
        stamp.write(besides: extract)
    }

    private var damaged: Data {
        var bytes = body
        bytes.replaceSubrange(100..<164, with: Data(count: 64))
        return bytes
    }

    func testADamagedCopyIsNeverTheFallback() async throws {
        let published = MD5.hex(of: body)
        try await cached(damaged, stamp: CacheStamp(size: Int64(body.count), lastModified: nil, md5: published))
        failing.withLock { $0 = true }
        do {
            _ = try await pipeline().downloadExtracts()
            XCTFail("built from a copy found damaged")
        } catch {}
    }

    /// Found damaged against the checksum while the mirror gives no date, the copy loses the
    /// date on its stamp: the next build hashes it rather than trusting it.
    func testACopyFoundDamagedStopsVouching() async throws {
        let published = MD5.hex(of: body)
        try await cached(
            damaged,
            stamp: CacheStamp(size: Int64(body.count), lastModified: Self.modified, md5: published)
        )
        headFails.withLock { $0 = true }
        failing.withLock { $0 = true }
        do {
            _ = try await pipeline().downloadExtracts()
            XCTFail("built from a copy found damaged")
        } catch {}
        XCTAssertNil(CacheStamp.read(besides: extract)?.lastModified)
        headFails.withLock { $0 = false }
        failing.withLock { $0 = false }
        let fetched = try await pipeline().downloadExtracts()
        XCTAssertEqual(try Data(contentsOf: fetched[0]), body)
    }

    /// A copy moves aside or back whole: another kmap waits rather than meeting it half moved.
    func testSettlingWaitsForAPutAsideUnderWay() throws {
        Paths.ensure(extract.deletingLastPathComponent())
        Paths.ensure(Paths.locks)
        try FileTools.write(damaged, to: extract.appendingPathExtension("suspect"))
        CacheStamp(size: Int64(body.count), lastModified: Self.modified, md5: "x").write(besides: extract)
        let name = "suspect-\(FileTools.slugify(extract.lastPathComponent)).lock"
        var held = HeldLock(trying: Paths.locks.appendingPathComponent(name))
        XCTAssertEqual(held?.isHeld, true)
        let settled = expectation(description: "settled")
        let extract = extract
        DispatchQueue.global().async {
            BuildPipeline.settleSuspect(besides: extract)
            settled.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileTools.exists(extract), "settled while the copy was being put aside")
        held = nil
        wait(for: [settled], timeout: 10)
        XCTAssertTrue(FileTools.exists(extract))
        XCTAssertNil(CacheStamp.read(besides: extract)?.lastModified)
    }

    func testAStaleCopyIsStillTheFallback() async throws {
        try await cached(damaged, stamp: CacheStamp(size: Int64(body.count), lastModified: nil, md5: "an older one"))
        failing.withLock { $0 = true }
        let fallen = try await pipeline().downloadExtracts()
        XCTAssertEqual(fallen, [extract])
    }

    /// A copy put back during the fetch is no fallback.
    func testACopyPutBackMeanwhileIsNotTheFallback() async throws {
        let published = MD5.hex(of: body)
        try await cached(
            damaged,
            stamp: CacheStamp(size: Int64(body.count), lastModified: Self.modified, md5: published)
        )
        _ = BuildPipeline.putAside(extract)
        XCTAssertFalse(FileTools.exists(extract))
        let extract = extract
        meanwhile.withLock { $0 = { BuildPipeline.settleSuspect(besides: extract) } }
        failing.withLock { $0 = true }
        do {
            _ = try await pipeline().downloadExtracts()
            XCTFail("built from a copy put back meanwhile")
        } catch {}
        XCTAssertNil(CacheStamp.read(besides: extract)?.lastModified, "put back, its stamp vouches for nothing")
    }

    /// A stale copy put aside and back by another kmap during the fetch is not the copy the
    /// check saw: no fallback.
    func testACopyReplacedMeanwhileIsNotTheFallback() async throws {
        try await cached(
            damaged,
            stamp: CacheStamp(
                size: Int64(body.count),
                lastModified: "Mon, 05 Oct 2026 20:00:00 GMT",
                md5: "an older one"
            )
        )
        let extract = extract
        meanwhile.withLock {
            $0 = {
                _ = BuildPipeline.putAside(extract)
                BuildPipeline.settleSuspect(besides: extract)
            }
        }
        failing.withLock { $0 = true }
        do {
            _ = try await pipeline().downloadExtracts()
            XCTFail("fell back on a copy replaced meanwhile")
        } catch {}
    }
}
#endif
