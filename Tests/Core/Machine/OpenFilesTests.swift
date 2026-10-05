import XCTest

@testable import kmap

#if canImport(Glibc)
import Glibc
#endif

final class OpenFilesTests: XCTestCase {
    #if !os(Windows)
    #if os(Linux)
    private let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
    #else
    private let resource = RLIMIT_NOFILE
    #endif

    func testTheLimitIsRaisedForATileSplit() throws {
        var saved = rlimit()
        XCTAssertEqual(getrlimit(resource, &saved), 0)
        defer { _ = setrlimit(resource, &saved) }
        guard saved.rlim_max >= 512 else { throw XCTSkip("the hard limit is \(saved.rlim_max)") }
        var low = saved
        low.rlim_cur = 128
        XCTAssertEqual(setrlimit(resource, &low), 0)

        Machine.allowOpenFiles(400)
        var now = rlimit()
        XCTAssertEqual(getrlimit(resource, &now), 0)
        XCTAssertEqual(now.rlim_cur, 400)

        // Never lowered.
        Machine.allowOpenFiles(200)
        XCTAssertEqual(getrlimit(resource, &now), 0)
        XCTAssertEqual(now.rlim_cur, 400)
    }
    #endif
}
