import Foundation

/// The system file dialog.
///
/// Windows shows its own, in this process — see `WindowsFileDialog`. Everywhere else a
/// helper is run and asked for a path: `osascript` on macOS, `powershell.exe` under WSL,
/// and whichever of zenity, kdialog or qarma a Linux desktop has. `isAvailable` is false
/// where there is none, so callers can omit the action.
enum FilePicker {

    enum Wanted: Equatable {
        /// A file, optionally narrowed to these extensions.
        case file(extensions: [String])
        case directory
    }

    /// The dialect a dialog is asked in, independent of the platform.
    enum Kind: Equatable {
        case osascript
        /// Windows's own dialog, driven through `powershell.exe`.
        case powershell
        case zenity
        case kdialog
        case qarma
    }

    struct Helper: Equatable {
        let path: String
        let kind: Kind

        /// Whether the returned path must be translated before this process can open
        /// it. A property of the platform, not the dialect: the PowerShell dialog answers
        /// in Windows paths under both WSL and Windows, and only WSL must convert them.
        var answersInForeignPaths = false
    }

    /// Whether a dialog can be shown. False with no display, with none of the Linux
    /// helpers installed, and under WSL with interop off. Always true on Windows, whose
    /// dialogs kmap shows itself.
    static var isAvailable: Bool {
        #if os(Windows)
        return true
        #else
        return helper() != nil
        #endif
    }

    /// Shows the dialog and blocks until it closes.
    ///
    /// - Returns: The chosen path, or nil when cancelled, when no helper exists, or
    ///   under test.
    static func choose(_ wanted: Wanted, startingAt start: URL? = nil,
                       prompt: String) -> URL? {
        // Never under test: an unattended dialog blocks until it is closed.
        guard !underTest else { return nil }
        // The console is remembered and taken back around every dialog: on the Unixes and
        // under WSL the helper is a child that shares it, and on Windows the dialog is a
        // window of this process's own that the screen has to be drawn again under.
        Terminal.shared?.lend()
        defer { Terminal.shared?.reclaim() }
        #if os(Windows)
        // Windows's own dialogs, in this process. A helper would share this console and
        // hand it back changed — see WindowsFileDialog.
        let start = start.flatMap { Platform.windowsPath(for: $0) }
        let chosen: String?
        switch wanted {
        case .file(let extensions):
            chosen = WindowsFileDialog.file(extensions: extensions, startingAt: start,
                                            title: prompt)
        case .directory:
            chosen = WindowsFileDialog.directory(startingAt: start, title: prompt)
        }
        return chosen.map { URL(fileURLWithPath: $0) }
        #else
        guard let helper = helper() else { return nil }
        let output = ProcessProbe.capture(helper.path,
                                           arguments(for: helper.kind, wanted: wanted,
                                                     startingAt: start, prompt: prompt),
                                           timeout: 600)
        return output.flatMap {
            path(from: $0, kind: helper.kind, translating: helper.answersInForeignPaths)
        }
        #endif
    }

    /// Whether this process is a test run.
    static var underTest: Bool {
        let info = ProcessInfo.processInfo
        if info.processName == "xctest" || info.processName.hasSuffix(".xctest") { return true }
        if info.arguments.first?.hasSuffix("/xctest") == true { return true }
        return info.environment["XCTestConfigurationFilePath"] != nil
            || info.environment["XCTestBundlePath"] != nil
    }

    // MARK: What to run

    /// Returns the first dialog helper this platform has, or nil. What a native Windows
    /// build answers here is not used: it shows the dialogs itself. Its entry stands for
    /// the WSL side, which asks the same PowerShell for the same dialog.
    static func helper(platform: Platform = Platform.current,
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       exists: (String) -> Bool = { FileTools.isExecutable($0) })
        -> Helper? {
        switch platform {
        case .macOS:
            return exists("/usr/bin/osascript")
                ? Helper(path: "/usr/bin/osascript", kind: .osascript) : nil

        case .wsl:
            // The Windows dialog is present whenever interop is on, and can see the
            // drives removable media is mounted on.
            if let powershell = Platform.which("powershell.exe", environment: environment,
                                               on: platform, exists: exists) {
                return Helper(path: powershell, kind: .powershell,
                              answersInForeignPaths: true)
            }
            // Interop off; WSLg may still provide a Linux desktop.
            return linuxHelper(platform: platform, environment: environment, exists: exists)

        case .windows:
            // The same dialog, with no translation on the way back.
            guard let powershell = Platform.which("powershell.exe", environment: environment,
                                                  on: platform, exists: exists)
            else { return nil }
            return Helper(path: powershell, kind: .powershell)

        case .linux:
            return linuxHelper(platform: platform, environment: environment, exists: exists)
        }
    }

    private static func linuxHelper(platform: Platform = .linux,
                                    environment: [String: String],
                                    exists: (String) -> Bool) -> Helper? {
        // Without a display these helpers hang and then fail.
        guard environment["DISPLAY"] != nil || environment["WAYLAND_DISPLAY"] != nil else {
            return nil
        }
        for (name, kind) in [("zenity", Kind.zenity), ("kdialog", .kdialog), ("qarma", .qarma)] {
            if let found = Platform.which(name, environment: environment, on: platform,
                                          exists: exists) {
                return Helper(path: found, kind: kind)
            }
        }
        return nil
    }

    /// Returns the arguments that put up one dialog in `kind`'s dialect.
    static func arguments(for kind: Kind, wanted: Wanted, startingAt start: URL?,
                          prompt: String,
                          windowsPath: (URL) -> String? = { Platform.windowsPath(for: $0) })
        -> [String] {
        // The prompt is arbitrary text and lands inside quoted strings, so quotes and
        // newlines are removed.
        let title = prompt.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")

        switch kind {
        case .osascript:
            var script: String
            switch wanted {
            case .directory:
                script = "choose folder with prompt \"\(title)\""
            case .file(let extensions):
                script = "choose file with prompt \"\(title)\""
                if !extensions.isEmpty {
                    let types = extensions.map { "\"\($0)\"" }.joined(separator: ", ")
                    script += " of type {\(types)}"
                }
            }
            if let start {
                // AppleScript names a POSIX path, which on macOS is also the native one.
                script += " default location POSIX file \"\(start.path)\""
            }
            return ["-e", "POSIX path of (\(script))"]

        case .powershell:
            return ["-NoProfile", "-NonInteractive", "-Sta", "-EncodedCommand",
                    encoded(powershellScript(wanted: wanted, title: title,
                                             startingAt: start.flatMap(windowsPath)))]

        case .zenity, .qarma:
            var out = ["--file-selection", "--title=\(title)"]
            if case .directory = wanted { out.append("--directory") }
            if let start {
                // A trailing slash means "start inside this folder".
                let directory = start.hasDirectoryPath ? start.path + "/" : start.path
                out.append("--filename=\(directory)")
            }
            if case .file(let extensions) = wanted, !extensions.isEmpty {
                let patterns = extensions.map { "*.\($0)" }.joined(separator: " ")
                out.append("--file-filter=\(patterns)")
            }
            return out

        case .kdialog:
            let location = start?.path ?? "."
            switch wanted {
            case .directory:
                return ["--getexistingdirectory", location, "--title", title]
            case .file(let extensions):
                let patterns = extensions.isEmpty
                    ? "*" : extensions.map { "*.\($0)" }.joined(separator: " ")
                return ["--getopenfilename", location, patterns, "--title", title]
            }
        }
    }

    // MARK: The Windows dialog

    /// Returns the script for `powershell.exe`: `OpenFileDialog` for a file,
    /// `FolderBrowserDialog` for a directory.
    ///
    /// Passed base64-encoded via `-EncodedCommand`, so quotes and backslashes survive
    /// reassembly into a single command line across the interop boundary.
    private static func powershellScript(wanted: Wanted, title: String, startingAt start: String?) -> String {
        // Single-quoted PowerShell strings are literal; a quote is escaped by doubling.
        func quoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        }

        var lines = [
            // Progress reporting on a redirected stream is serialised as CLIXML and
            // glued onto the answer; silencing it removes that at the source.
            "$ProgressPreference = 'SilentlyContinue'",
            // So non-ASCII path components survive the pipe back.
            "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8",
            "Add-Type -AssemblyName System.Windows.Forms"
        ]
        switch wanted {
        case .file(let extensions):
            lines.append("$d = New-Object System.Windows.Forms.OpenFileDialog")
            lines.append("$d.Title = \(quoted(title))")
            if !extensions.isEmpty {
                let patterns = extensions.map { "*.\($0)" }.joined(separator: ";")
                lines.append("$d.Filter = \(quoted("Supported|\(patterns)|All files|*.*"))")
            }
            if let start { lines.append("$d.InitialDirectory = \(quoted(start))") }
            lines.append("if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)"
                         + " { [Console]::Out.Write($d.FileName) }")
        case .directory:
            lines.append("$d = New-Object System.Windows.Forms.FolderBrowserDialog")
            lines.append("$d.Description = \(quoted(title))")
            if let start { lines.append("$d.SelectedPath = \(quoted(start))") }
            lines.append("if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)"
                         + " { [Console]::Out.Write($d.SelectedPath) }")
        }
        return lines.joined(separator: "\n")
    }

    /// Strips the CLIXML that PowerShell wraps a redirected stream in.
    ///
    /// The `<Objs …>` blob arrives glued onto the answer rather than on a line of its
    /// own, so line-wise parsing alone cannot skip it.
    static func withoutSerialisedObjects(_ output: String) -> String {
        var text = output
        if let start = text.range(of: "<Objs ") {
            text = String(text[text.startIndex..<start.lowerBound])
        }
        return Lines.of(text)
            .filter { !$0.hasPrefix("#< CLIXML") }
            .joined(separator: "\n")
    }

    /// Encodes `script` as UTF-16 little-endian base64, the form `-EncodedCommand` takes.
    static func encoded(_ script: String) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(script.utf16.count * 2)
        for unit in script.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return Data(bytes).base64EncodedString()
    }

    // MARK: What came back

    /// Parses what the helper printed into a path.
    ///
    /// - Returns: The path, or nil for anything that is not one: a cancellation, reported
    ///   differently by each helper, or a failed helper.
    static func path(from output: String, kind: Kind = .osascript,
                     translating: Bool = false,
                     toLinux: (String) -> String? = Platform.linuxPath(for:)) -> URL? {
        // Stripping follows the dialect; translating the answer follows the platform.
        let cleaned = kind == .powershell ? withoutSerialisedObjects(output) : output
        let line = Lines.of(cleaned)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return nil }

        if translating {
            // A path off the mounted drives, such as a network share, has no Linux
            // equivalent.
            guard let converted = toLinux(line) else { return nil }
            return URL(fileURLWithPath: converted)
        }

        // A drive-letter path is opened as it stands.
        if kind == .powershell { return URL(fileURLWithPath: line) }

        guard line.hasPrefix("/") else { return nil }
        // osascript returns a folder with a trailing slash; kmap keeps paths without one.
        let trimmed = line.count > 1 && line.hasSuffix("/") ? String(line.dropLast()) : line
        return URL(fileURLWithPath: trimmed)
    }
}
