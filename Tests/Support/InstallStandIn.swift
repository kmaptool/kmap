import Foundation
import XCTest
@testable import kmap

/// Stands in for `Toolchain.install`: an install holds until it is released, failed or
/// cancelled, the way a download does, and a ledger says what happened to each id.
final class InstallStandIn: @unchecked Sendable {
    struct Failed: Error, LocalizedError {
        var errorDescription: String? { "did not work" }
    }

    private let lock = NSLock()
    private var started: [String] = []
    private var cancelled: [String] = []
    private var released: Set<String> = []
    private var failing: Set<String> = []

    var installer: ToolInstaller {
        { id, _, _, _ in
            self.lock.withLock { self.started.append(id) }
            while true {
                let (go, fail) = self.lock.withLock {
                    (self.released.contains(id), self.failing.contains(id))
                }
                if fail { throw Failed() }
                if go { return }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000)
                } catch {
                    // What a download does when its task is cancelled.
                    self.lock.withLock { self.cancelled.append(id) }
                    throw error
                }
            }
        }
    }

    /// Lets the install of `id` finish well.
    func release(_ id: String) { lock.withLock { _ = released.insert(id) } }
    /// Makes the install of `id` fail.
    func fail(_ id: String) { lock.withLock { _ = failing.insert(id) } }

    var startedIDs: [String] { lock.withLock { started } }
    var cancelledIDs: [String] { lock.withLock { cancelled } }
    func timesStarted(_ id: String) -> Int { lock.withLock { started.filter { $0 == id }.count } }
}

/// Polls `condition` until it holds or `seconds` pass. The screens finish an install on
/// the main actor from another task, so a test has to give that hop a moment.
@MainActor
func settles(within seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

/// `settles`, as an assertion: fails on the caller's line when the condition never holds.
@MainActor
func expectSettled(_ message: String = "", within seconds: Double = 3,
                   file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async {
    let held = await settles(within: seconds, condition)
    XCTAssertTrue(held, message, file: file, line: line)
}
