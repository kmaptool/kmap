import XCTest

@testable import kmap

#if !os(Windows)
final class CLIInterruptsTests: XCTestCase {
    private func isIgnored(_ number: Int32) -> Bool {
        let previous = signal(number, SIG_IGN)
        signal(number, previous)
        return previous.map { unsafeBitCast($0, to: Int.self) } == 1
    }

    /// Under nohup the hang-up stays ignored and unwatched; the rest come back as they were.
    func testASignalTheCallerIgnoredIsLeftAlone() {
        let hangUp = signal(SIGHUP, SIG_IGN)
        // As a shell's background job would not leave them.
        let interrupt = signal(SIGINT, SIG_DFL), terminate = signal(SIGTERM, SIG_DFL)
        defer {
            signal(SIGHUP, hangUp)
            signal(SIGINT, interrupt)
            signal(SIGTERM, terminate)
        }
        let watch = CLI.watchInterrupts {}
        XCTAssertEqual(watch.sources.count, 2, "Ctrl+C and the polite kill only")
        watch.stop()
        XCTAssertTrue(isIgnored(SIGHUP))
        XCTAssertFalse(isIgnored(SIGINT), "put back as it was")
    }
}
#endif
