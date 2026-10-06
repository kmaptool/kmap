#if !os(Windows)
import XCTest

@testable import kmap

/// The downloader against a server of this machine that misbehaves as real ones do.
final class DownloaderServerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The file's bytes, a version apart where it was replaced on the server.
    private static func body(_ count: Int, version: Int = 0) -> Data {
        Data((0..<count).map { UInt8(($0 * 7 + version * 13) & 0xFF) })
    }

    /// The first and last byte a `Range` header asks, the last bounded by the file.
    private static func range(_ header: String?, size: Int) -> ClosedRange<Int>? {
        guard let spec = header?.split(separator: "=").last else { return nil }
        let ends = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let from = Int(ends[0]) else { return nil }
        let to = ends.count > 1 ? Int(ends[1]) ?? size - 1 : size - 1
        return from...min(to, size - 1)
    }

    private func fetch(
        _ server: LoopbackServer,
        _ path: String,
        connections: Int,
        with downloader: Downloader = Downloader(log: Log())
    ) async throws -> Data {
        let destination = directory.appendingPathComponent("file")
        try await downloader.download(url: server.url(path), to: destination, connections: connections)
        return try Data(contentsOf: destination)
    }

    /// A proxy that relays at most 64 KiB of any range: each answer is clean but short,
    /// and the rest is asked for again.
    func testAServerCappingRangesStillDeliversTheWholeFile() async throws {
        let size = 1_000_000
        let file = Self.body(size)
        let server = try LoopbackServer { request in
            guard let range = Self.range(request.header("Range"), size: size) else {
                return .init(
                    status: 200,
                    headers: [("Content-Length", "\(size)"), ("Accept-Ranges", "bytes")],
                    body: file
                )
            }
            let end = min(range.upperBound, range.lowerBound + 65_535)
            return .init(
                status: 206,
                headers: [
                    ("Content-Length", "\(end - range.lowerBound + 1)"),
                    ("Content-Range", "bytes \(range.lowerBound)-\(end)/\(size)"), ("Accept-Ranges", "bytes")
                ],
                body: file.subdata(in: range.lowerBound..<(end + 1))
            )
        }
        defer { server.stop() }
        let got = try await fetch(server, "/capped", connections: 2)
        XCTAssertEqual(got, file)
    }

    /// The file is replaced on the server after the first half arrived: the download
    /// starts over on the new copy rather than splicing the 2.
    func testAFileReplacedMidwayIsFetchedAgainNotSpliced() async throws {
        let size = 400_000
        let gets = Locked(0)
        let server = try LoopbackServer { request in
            let version = gets.withLock { $0 } == 0 ? 0 : 1
            let modified = "Mon, 0\(version + 1) Jan 2024 00:00:00 GMT"
            let file = Self.body(size, version: version)
            var headers = [("Accept-Ranges", "bytes"), ("Last-Modified", modified)]
            guard request.method == "GET" else {
                return .init(status: 200, headers: headers + [("Content-Length", "\(size)")])
            }
            let first = gets.withLock { count in
                count += 1
                return count == 1
            }
            guard let range = Self.range(request.header("Range"), size: size),
                request.header("If-Range").map({ $0 == modified }) ?? true
            else {
                return .init(status: 200, headers: headers + [("Content-Length", "\(size)")], body: file)
            }
            headers += [
                ("Content-Length", "\(range.count)"),
                ("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)")
            ]
            let slice = file.subdata(in: range.lowerBound..<(range.upperBound + 1))
            return .init(status: 206, headers: headers, body: slice, cut: first ? slice.count / 2 : nil)
        }
        defer { server.stop() }
        let got = try await fetch(server, "/replaced", connections: 1)
        XCTAssertEqual(got, Self.body(size, version: 1))
    }

    /// A server that serves no ranges drops the connection once: the file is fetched
    /// again from the top.
    func testAServerWithoutRangesIsAskedAgainFromTheTop() async throws {
        let size = 300_000
        let file = Self.body(size)
        let gets = Locked(0)
        let server = try LoopbackServer { request in
            let headers = [("Content-Length", "\(size)")]
            guard request.method == "GET" else { return .init(status: 200, headers: headers) }
            let first = gets.withLock { count in
                count += 1
                return count == 1
            }
            return .init(status: 200, headers: headers, body: file, cut: first ? size / 3 : nil)
        }
        defer { server.stop() }
        let downloader = Downloader(log: Log())
        let got = try await fetch(server, "/plain", connections: 2, with: downloader)
        XCTAssertEqual(got, file)
        // Started over, the bytes of the dropped try are not counted twice.
        XCTAssertEqual(downloader.progress.fraction, 1, accuracy: 0.001)
    }

    /// A file smaller than the connections asked: no part is left empty and unmade.
    func testAOneByteFileOverSeveralConnections() async throws {
        let file = Self.body(1)
        let server = try LoopbackServer { request in
            let headers = [("Content-Length", "1"), ("Accept-Ranges", "bytes")]
            if request.header("Range") != nil {
                return .init(status: 206, headers: headers + [("Content-Range", "bytes 0-0/1")], body: file)
            }
            return .init(status: 200, headers: headers, body: file)
        }
        defer { server.stop() }
        let got = try await fetch(server, "/tiny", connections: 4)
        XCTAssertEqual(got, file)
    }
}
#endif
