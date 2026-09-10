import Foundation

/// The machine's own package manager, for the dependencies kmap cannot ship: a Java
/// runtime, Python 3 with venv, and unzip.
///
/// Where kmap may run an install unattended it does; otherwise it prints the command
/// this manager would need. See `Privilege`.
enum PackageManager: String, CaseIterable, Equatable {
    case homebrew
    case apt
    case dnf
    case yum
    case pacman
    case zypper
    case apk
    case xbps
    /// Windows's own.
    case winget

    /// The program to run.
    var binary: String {
        switch self {
        case .homebrew: return "brew"
        case .apt: return "apt-get"
        case .dnf: return "dnf"
        case .yum: return "yum"
        case .pacman: return "pacman"
        case .zypper: return "zypper"
        case .apk: return "apk"
        case .xbps: return "xbps-install"
        case .winget: return "winget"
        }
    }

    /// The name to print, which is not always `binary`: `apt-get` is run for its stable
    /// scripting interface, while `apt` is what a person types.
    var spokenName: String { self == .apt ? "apt" : binary }


    /// Whether installing needs root. False for Homebrew, which refuses to run as root,
    /// and for winget, whose default scope is per-user.
    var needsRoot: Bool { self != .homebrew && self != .winget }

    /// Returns the arguments that install `packages` non-interactively. These run with
    /// stdin on the null device, so a manager that stopped to confirm would hang.
    func installArguments(_ packages: [String]) -> [String] {
        switch self {
        case .homebrew: return ["install"] + packages
        case .apt: return ["install", "-y", "--no-install-recommends"] + packages
        case .dnf, .yum: return ["install", "-y"] + packages
        case .pacman: return ["-S", "--needed", "--noconfirm"] + packages
        case .zypper: return ["--non-interactive", "install"] + packages
        case .apk: return ["add", "--no-cache"] + packages
        case .xbps: return ["-Sy"] + packages
        case .winget:
            // winget stops to ask for these otherwise, with no terminal to ask on.
            return ["install", "--silent", "--disable-interactivity",
                    "--accept-package-agreements", "--accept-source-agreements", "--id"]
                + packages
        }
    }

    /// Returns this manager's package names for `what`, or nil where it has none.
    func packages(for what: Need) -> [String]? {
        switch (self, what) {
        case (.homebrew, .java): return ["openjdk"]
        case (.apt, .java): return ["default-jdk"]
        case (.dnf, .java), (.yum, .java): return ["java-latest-openjdk-devel"]
        case (.pacman, .java): return ["jdk-openjdk"]
        case (.zypper, .java): return ["java-openjdk-devel"]
        case (.apk, .java): return ["openjdk21"]
        case (.xbps, .java): return ["openjdk"]
        // winget names packages by publisher and product, not by binary name.
        case (.winget, .java): return ["Microsoft.OpenJDK.21"]

        // On apt distributions venv is a separate package, and kmap builds one.
        case (.homebrew, .python): return ["python"]
        case (.apt, .python): return ["python3", "python3-venv"]
        case (.dnf, .python), (.yum, .python): return ["python3"]
        case (.pacman, .python): return ["python"]
        case (.zypper, .python): return ["python3"]
        case (.apk, .python): return ["python3"]
        case (.xbps, .python): return ["python3"]
        case (.winget, .python): return ["Python.Python.3.12"]

        // Not in winget's catalogue, and not needed: Windows ships `tar`.
        case (.winget, .unzip): return nil

        case (_, .unzip): return ["unzip"]
        }
    }

    /// The dependencies a package manager is asked for.
    enum Need: Equatable {
        case java, python, unzip
    }

    // MARK: Finding it

    /// Returns the manager this machine uses, or nil where none is installed.
    ///
    /// Where several are present the first in the platform's order wins: Homebrew on
    /// macOS, since it needs no root, and the distribution's own on Linux.
    static func detect(on platform: Platform = Platform.current,
                       which: (String) -> String? = { Platform.which($0) }) -> PackageManager? {
        let order: [PackageManager]
        switch platform {
        case .macOS:
            order = [.homebrew, .apt, .dnf, .pacman, .zypper, .apk, .xbps, .yum]
        case .windows:
            order = [.winget]
        case .linux, .wsl:
            // A WSL install has an ordinary distribution package manager.
            order = [.apt, .dnf, .pacman, .zypper, .apk, .xbps, .yum, .homebrew]
        }
        return order.first { which($0.binary) != nil }
    }
}

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
    static func forInstalling(with manager: PackageManager,
                              isRoot: Bool = Privilege.isRoot(),
                              hasSudo: Bool = Platform.which("sudo") != nil,
                              sudoIsPasswordless: @autoclosure () -> Bool = Privilege.sudoIsPasswordless())
        -> Privilege {
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

extension PackageManager {

    /// Returns the command that installs `what` and whether kmap may run it, or nil
    /// where this manager has no package for it.
    func command(for what: Need, privilege: Privilege)
        -> (executable: String, arguments: [String], runnable: Bool)? {
        guard let packages = packages(for: what) else { return nil }
        let arguments = installArguments(packages)
        switch privilege {
        case .direct:
            return (binary, arguments, true)
        case .passwordlessSudo:
            return ("sudo", [binary] + arguments, true)
        case .wouldAsk:
            // Not runnable, but the right words to show for this machine.
            return ("sudo", [binary] + arguments, false)
        }
    }

    /// Returns the install command as a person would type it for this manager.
    func spokenCommand(for what: Need, privilege: Privilege) -> String? {
        guard let packages = packages(for: what) else { return nil }
        let front = spokenName == binary ? binary : spokenName
        let verb = installArguments(packages)
        let root = needsRoot && privilege != .direct ? "sudo " : ""
        // The spoken name is printed; the arguments are the same either way.
        return root + front + " " + verb.joined(separator: " ")
    }
}
