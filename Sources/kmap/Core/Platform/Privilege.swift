import Foundation

/// Whether a system install can run here without a password prompt.
///
/// The interface holds the terminal in raw mode and gives children a null stdin, so a
/// password prompt would wait invisibly. The answer is settled before anything is run.
enum Privilege: Equatable {
    /// Homebrew, or a manager already running as root.
    case direct
    /// `sudo` runs it without prompting.
    case passwordlessSudo
    /// It would prompt, so kmap does not run it.
    case wouldAsk

    var canRunUnattended: Bool { self != .wouldAsk }

    /// Returns how far kmap may go in running `manager` here.
    ///
    /// - Parameter isRoot: Whether this process is already uid 0.
    /// - Parameter sudoIsPasswordless: Whether sudo would run without prompting.
    static func forInstalling(
        with manager: PackageManager,
        isRoot: Bool = Privilege.isRoot(),
        hasSudo: Bool = Platform.which("sudo") != nil,
        sudoIsPasswordless: @autoclosure () -> Bool = Privilege.sudoIsPasswordless()
    ) -> Privilege {
        if !manager.needsRoot { return .direct }
        if isRoot { return .direct }
        guard hasSudo, sudoIsPasswordless() else { return .wouldAsk }
        return .passwordlessSudo
    }

    /// Whether this process is uid 0. Always false on Windows, where the only manager
    /// needs no elevation.
    static func isRoot() -> Bool {
        #if os(Windows)
        return false
        #else
        return getuid() == 0
        #endif
    }

    /// Runs `sudo -n true`: `-n` makes sudo fail rather than read a terminal, so the
    /// check cannot become the prompt it tests for.
    static func sudoIsPasswordless(
        runner: (String, [String]) -> Int32? = { executable, arguments in
            ProcessProbe.exitCode(executable, arguments, timeout: 5)
        }
    ) -> Bool {
        guard let sudo = Platform.which("sudo") else { return false }
        return runner(sudo, ["-n", "true"]) == 0
    }
}
