import Foundation

/// One external dependency kmap drives.
struct ToolStatus {
    enum State {
        case ready, missing, broken
    }

    let id: String
    let name: String
    let detail: String  // what it is used for
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
