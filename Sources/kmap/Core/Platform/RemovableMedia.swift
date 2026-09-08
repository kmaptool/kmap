import Foundation

/// Locations of removable volumes: one directory on macOS, several on Linux depending
/// on the mounting desktop, and drive letters on Windows.
extension Platform {

    /// Returns the directories removable volumes are mounted under. Under WSL these are
    /// the Windows drives, which WSL exposes below `/mnt`.
    ///
    /// Callers stat one known subdirectory per entry; the roots are never walked.
    static func mediaRoots(_ platform: Platform = Platform.current,
                           environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [String] {
        switch platform {
        case .macOS:
            return ["/Volumes"]
        case .wsl:
            return ["/mnt", "/media"]
        case .windows:
            // Windows has no directory whose children are the volumes; a drive is itself
            // a name at the top of the namespace. `mountedVolumes` asks the letters.
            return []
        case .linux:
            // udisks2 uses `/media/<user>`, systemd-based distributions
            // `/run/media/<user>`; `/media` and `/mnt` hold hand-made mounts.
            var out = ["/media", "/run/media", "/mnt"]
            if let user = environment["USER"] ?? environment["LOGNAME"], !user.isEmpty {
                out.insert("/media/" + user, at: 0)
                out.insert("/run/media/" + user, at: 1)
            }
            return out
        }
    }

    /// Returns every mounted volume as a directory to look inside.
    static func mountedVolumes(
        _ platform: Platform = Platform.current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        contents: (String) -> [String] = { root in
            ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
        },
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        if platform.usesWindowsPaths { return windowsDrives(exists: exists) }

        var out: [URL] = []
        var seen = Set<String>()
        for root in mediaRoots(platform, environment: environment) {
            for entry in contents(root) where !entry.hasPrefix(".") {
                let path = root + "/" + entry
                if seen.insert(path).inserted { out.append(URL(fileURLWithPath: path)) }
            }
        }
        return out
    }

    /// Returns the drive letters present on this machine, as root paths.
    ///
    /// Probed with `exists` rather than `GetLogicalDrives` so the result is paths and the
    /// set is injectable. A and B are skipped: probing an empty floppy drive can raise a
    /// system dialog.
    static func windowsDriveRoots(exists: (String) -> Bool) -> [String] {
        "CDEFGHIJKLMNOPQRSTUVWXYZ".map { "\($0):\\" }.filter(exists)
    }

    /// Returns `windowsDriveRoots` as directory URLs.
    static func windowsDrives(exists: (String) -> Bool) -> [URL] {
        windowsDriveRoots(exists: exists).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
