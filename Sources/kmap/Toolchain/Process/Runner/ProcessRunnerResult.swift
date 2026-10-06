import Foundation

extension ProcessRunner {
    struct Result {
        let exitCode: Int32
        let tail: [String]  // last lines, for error reporting
    }
}
