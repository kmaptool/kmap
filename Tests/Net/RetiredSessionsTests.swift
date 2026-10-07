import XCTest

@testable import kmap

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where URLSession runs on libcurl, a session kmap is done with is never freed: freeing
/// one there crashes the process on Ubuntu 26.04.
final class RetiredSessionsTests: XCTestCase {
    func testARetiredSessionOutlivesItsLastUserWhereCurlRunsIt() {
        let before = RetiredSessions.count
        weak var retired: URLSession?
        do {
            let session = URLSession(configuration: .ephemeral)
            retired = session
            RetiredSessions.cancel(session)
        }
        #if canImport(FoundationNetworking)
        XCTAssertNotNil(retired)
        XCTAssertEqual(RetiredSessions.count, before + 1)
        #else
        XCTAssertEqual(RetiredSessions.count, 0)
        #endif
    }

    func testASessionRetiredTwiceIsKeptOnce() {
        let before = RetiredSessions.count
        let session = URLSession(configuration: .ephemeral)
        RetiredSessions.cancel(session)
        RetiredSessions.finish(session)
        #if canImport(FoundationNetworking)
        XCTAssertEqual(RetiredSessions.count, before + 1)
        #else
        XCTAssertEqual(RetiredSessions.count, 0)
        #endif
    }

    func testADownloaderLetGoOfRetiresItsSession() {
        let before = RetiredSessions.count
        do { _ = Downloader(log: Log()) }
        #if canImport(FoundationNetworking)
        XCTAssertEqual(RetiredSessions.count, before + 1)
        #else
        XCTAssertEqual(RetiredSessions.count, 0)
        #endif
    }
}
