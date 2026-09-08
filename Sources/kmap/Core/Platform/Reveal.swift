import Foundation

/// Showing a file in the desktop's file manager, which each platform is asked for
/// differently.
extension Platform {

    /// Returns the command that shows `url` in a file manager, or nil where no file
    /// manager is installed.
    ///
    /// macOS and Windows select the file; plain Linux opens its folder instead, since
    /// `xdg-open` cannot select and would launch a handler application for the file.
    static func revealCommand(for url: URL,
                              on platform: Platform = Platform.current,
                              which: (String) -> String? = { Platform.which($0) })
        -> (executable: String, arguments: [String])? {
        switch platform {
        case .macOS:
            guard let open = which("open") else { return nil }
            return (open, ["-R", url.path])
        case .wsl:
            // Windows Explorer needs a Windows path; the conversion can fail.
            guard let explorer = which("explorer.exe"),
                  let windows = windowsPath(for: url, on: .wsl) else {
                return revealCommand(for: url, on: .linux, which: which)
            }
            // No space after the comma: `/select,<path>` must be one argument, or
            // explorer.exe silently opens the default folder.
            return (explorer, ["/select,\(windows)"])
        case .windows:
            // The path is already the one Explorer wants; no translation.
            guard let explorer = which("explorer.exe") else { return nil }
            return (explorer, ["/select,\(url.nativePath)"])
        case .linux:
            guard let opener = which("xdg-open") ?? which("gio") ?? which("nautilus")
            else { return nil }
            if opener.hasSuffix("/gio") { return (opener, ["open", url.deletingLastPathComponent().path]) }
            return (opener, [url.deletingLastPathComponent().path])
        }
    }

    /// Whether any file manager is available. Resolved once: the answer searches `PATH`
    /// and is read on every redraw.
    static let canReveal: Bool = revealCommand(for: URL(fileURLWithPath: "/")) != nil

    /// Returns the label for the reveal action, in the platform's own wording.
    static func revealLabel(on platform: Platform = Platform.current) -> String {
        switch platform {
        case .macOS: return t("reveal in Finder")
        case .wsl, .windows: return t("show in Explorer")
        // xdg-open cannot select a file, so the label promises only the folder.
        case .linux: return t("open the folder")
        }
    }
}
