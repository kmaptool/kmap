import Foundation

/// The line to print when kmap cannot install something itself.
extension Platform {

    /// Returns the command that installs `what` with the package manager this machine
    /// has, or a download location when no known manager carries it.
    static func installHint(_ what: PackageManager.Need,
                            manager: PackageManager? = PackageManager.detect(),
                            privilege: Privilege? = nil) -> String {
        if let manager {
            let privilege = privilege ?? Privilege.forInstalling(with: manager)
            if let command = manager.spokenCommand(for: what, privilege: privilege) {
                return command
            }
        }
        // No manager, or one that does not carry this package.
        if let site = what.homepage {
            return t("download %@ from %@", what.spokenName, site)
        }
        return t("install %@ with this machine's package manager", what.spokenName)
    }
}

extension PackageManager.Need {
    /// What to call this when there is no command to print.
    var spokenName: String {
        switch self {
        case .java: return "a Java runtime"
        case .python: return "python3"
        case .unzip: return "unzip"
        }
    }

    /// The publisher's page, without a scheme, for typing by hand. Nil when no package
    /// manager is needed to obtain it.
    var homepage: String? {
        switch self {
        case .java: return "adoptium.net"
        case .python: return "python.org/downloads"
        // Every supported machine can already open a zip.
        case .unzip: return nil
        }
    }
}
