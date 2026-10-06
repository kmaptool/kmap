import Foundation

/// Whether this process may reach the network. A test run may not, and that is decided
/// here, as `Paths.root` decides where a test writes, rather than test by test.
///
/// A screen's `tick` starts fetches of its own in the background: the region index, the
/// packs' news. A test that drew whatever came back was drawing the network, not the
/// screen; and on Linux a fetch still under way as the test process exited made
/// FoundationNetworking's first session there, which libcurl refused, and the process
/// crashed after its tests had passed.
enum Network {
    static let isOpen = !Paths.isATestRun

    /// What a fetch in a test run throws. Not a URLError: nothing retries it, so a test
    /// that reaches for the network fails at once instead of sleeping through backoff.
    struct Closed: LocalizedError {
        var errorDescription: String? { "no network in a test run" }
    }

    /// Called first by everything that opens a connection. A test's own server on this
    /// machine is reached in a test run too.
    static func ensureOpen(_ url: URL? = nil) throws {
        guard isOpen || url.map(isLoopback) == true else { throw Closed() }
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
    }
}
