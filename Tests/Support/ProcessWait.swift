import Foundation
@testable import kmap

/// Enough for tar, zip and gpsbabel on a slow machine.
private let fixtureToolTimeout: TimeInterval = 60

/// XCTest runs on the main thread, where `waitUntilExit()` deadlocks on Linux.
func waitForExit(_ process: Process) {
    ChildProcess.waitForExit(process, within: fixtureToolTimeout)
}
