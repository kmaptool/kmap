import Foundation

/// Translation between the two spellings a path has across the WSL boundary. Only WSL
/// needs it: elsewhere a file has a single name.
extension Platform {

    /// Returns `url` as Windows would write it, or nil where Windows cannot reach it.
    /// On Windows the path is returned unchanged.
    ///
    /// `wslpath` is preferred because the mount point of the Windows drives is
    /// configurable in `wsl.conf`; `defaultWindowsPath` covers its absence.
    static func windowsPath(for url: URL,
                            on platform: Platform = Platform.current,
                            runner: (String, [String]) -> String? = { ProcessProbe.capture($0, $1, timeout: 5) })
        -> String? {
        // A native build has nothing to translate, and `wslpath` would reject the path.
        if platform.usesWindowsPaths { return url.nativePath }
        if let wslpath = which("wslpath"),
           let out = runner(wslpath, ["-w", url.path])?
               .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            return out
        }
        return defaultWindowsPath(for: url.path)
    }

    /// Maps `/mnt/<letter>/…` to `<LETTER>:\…`, and returns nil for anything else.
    ///
    /// The distribution's own filesystem is reachable as `\\wsl$\<distro>\…`, whose
    /// name is only known to `wslpath`.
    static func defaultWindowsPath(for path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // ["", "mnt", "e", …]
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "mnt",
              parts[2].count == 1, let drive = parts[2].first, drive.isLetter else { return nil }
        let rest = parts.dropFirst(3).joined(separator: "\\")
        return "\(drive.uppercased()):\\" + rest
    }

    /// Maps `<LETTER>:\…` to `/mnt/<letter>/…`, and returns nil for anything else.
    static func linuxPath(for windows: String) -> String? {
        let trimmed = windows.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let characters = Array(trimmed)
        guard characters[1] == ":", characters[0].isLetter else { return nil }
        let rest = String(characters.dropFirst(2))
            .replacingOccurrences(of: "\\", with: "/")
        let tail = rest.hasPrefix("/") ? String(rest.dropFirst()) : rest
        return "/mnt/\(characters[0].lowercased())/" + tail
    }
}
