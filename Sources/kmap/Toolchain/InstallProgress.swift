import Foundation

/// One install, as the screens run it: the real one is `Toolchain.install`, and a test
/// stands in something that holds until it is released or cancelled.
typealias ToolInstaller = (_ id: String, _ log: Log, _ runner: ProcessRunner,
                           _ progress: InstallProgress) async throws -> Void

/// What an install is doing now, for a screen to draw.
///
/// The installer writes; the render loop reads. A download reports its own fraction, and
/// the steps around it - unpacking, compiling, asking a package manager - report a stage
/// with no fraction, which the bar draws as indeterminate rather than as zero.
final class InstallProgress {
    private let lock = NSLock()
    private var _tool = ""
    private var _stage = ""
    private var _download: DownloadProgress?
    /// Which of a set of tools this is, for a screen installing several in a row.
    private var _index = 0
    private var _of = 0

    /// The tool being installed, by its spoken name.
    var tool: String { lock.withLock { _tool } }

    /// What is happening to it, in a few words.
    var stage: String { lock.withLock { _stage } }

    /// How far along, or nil where there is no number to give.
    var fraction: Double? {
        guard let download = lock.withLock({ _download }), download.total > 0 else { return nil }
        return download.fraction
    }

    /// Bytes in and bytes expected, or nil outside a download.
    var bytes: (received: Int64, total: Int64)? {
        guard let download = lock.withLock({ _download }), download.total > 0 else { return nil }
        return (download.received, download.total)
    }

    /// Bytes per second, or nil outside a download.
    var rate: Double? {
        guard let download = lock.withLock({ _download }) else { return nil }
        let rate = download.rate
        return rate > 0 ? rate : nil
    }

    /// Seconds still to come, or nil outside a download or before it can be estimated.
    var eta: Double? {
        guard let download = lock.withLock({ _download }), download.total > 0 else { return nil }
        let eta = download.eta
        return eta.isFinite ? eta : nil
    }

    /// Position in a run of several installs, counted from 1.
    var position: (index: Int, of: Int) { lock.withLock { (_index, _of) } }

    // MARK: Written by the installer

    /// Starts a tool, clearing whatever the last one left.
    func begin(_ tool: String, index: Int = 0, of count: Int = 0) {
        lock.withLock {
            _tool = tool
            _stage = ""
            _download = nil
            _index = index
            _of = count
        }
    }

    /// A step with no number to report.
    func step(_ stage: String) {
        lock.withLock {
            _stage = stage
            _download = nil
        }
    }

    /// A download, which reports its own progress from here on.
    func downloading(_ stage: String, _ download: DownloadProgress) {
        lock.withLock {
            _stage = stage
            _download = download
        }
    }

    func finish() {
        lock.withLock {
            _stage = ""
            _download = nil
        }
    }
}
