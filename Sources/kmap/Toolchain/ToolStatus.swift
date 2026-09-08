import Foundation

/// A JVM that starts, and the options it needs to start.
///
/// A JVM can be installed and still fail during VM initialization, when the reservation
/// of compressed class space cannot be satisfied; the heap size is unrelated. Options are
/// probed rather than assumed: a plain start first, a retry with the feature off second.
struct JavaRuntime: Equatable {
    let path: String
    let version: String
    /// Options this machine's JVM needs before it will start at all. Empty almost
    /// everywhere.
    let options: [String]

    /// `arguments`, with whatever this JVM needs in front of them. JVM options have to
    /// precede `-jar`, which is why this prepends rather than appends.
    func command(_ arguments: [String]) -> [String] { options + arguments }

    /// The same, for the tools that take JVM options only through `-J`.
    var toolOptions: [String] { options.map { "-J" + $0 } }

    /// Whether this is a whole JDK rather than a runtime: `javac` and `jar` stand beside
    /// it. Maps build without them; the seam patch is compiled with both.
    var isKit: Bool {
        FileTools.isExecutable(ToolLocations.companion("javac", of: path))
            && FileTools.isExecutable(ToolLocations.companion("jar", of: path))
    }
}

/// One external dependency kmap drives.
struct ToolStatus {
    enum State {
        case ready, missing, broken
    }

    let id: String
    let name: String
    let detail: String          // what it is used for
    var state: State
    var path: String?
    var version: String?
    var note: String?
    var installable: Bool
    /// A build works without it, so bulk installation skips it.
    var isOptional: Bool = false
    /// Ready, and there is still something to install: a Java that runs mkgmap but
    /// cannot compile is the one case. Without this a ready tool answers "already
    /// installed" and the offer above it leads nowhere.
    var moreToInstall: Bool = false

    /// Ready and complete, so an install would have nothing to do.
    var isFinished: Bool { isReady && !moreToInstall }
    /// Can be uninstalled again. True only for what kmap installed itself.
    var removable: Bool = false

    var isReady: Bool { state == .ready }
}
