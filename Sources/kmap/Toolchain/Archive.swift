import Foundation

/// Unpacking an archive, with whatever this machine has for the job.
///
/// Three operations: list the entries, read one to standard output, unpack into a
/// directory. For a zip that is `unzip` on macOS and Linux and bsdtar (`tar.exe`, shipped
/// since Windows 10 version 1803) on Windows, GNU tar being unable to read a zip at all.
/// For a gzip tarball it is `tar` everywhere, which every machine kmap runs on has.
struct Archive: Equatable {

    /// What is being unpacked. The zip is what mkgmap and the data packs are published
    /// as; the tarball is what a JDK is, outside Windows.
    enum Format: Equatable {
        case zip
        case tarGzip
    }

    enum Tool: Equatable {
        case unzip
        /// `tar`: bsdtar on Windows and macOS, GNU tar on Linux. Reads a tarball
        /// everywhere and a zip where it is bsdtar.
        case bsdtar
    }

    let tool: Tool
    /// The program itself, found on PATH rather than assumed at a fixed location.
    let path: String

    /// The name it is called by in messages.
    var name: String { tool == .unzip ? "unzip" : "tar" }

    // MARK: Finding one

    /// The unpacker this machine has for `format`, or nil.
    static func found(_ format: Format = .zip,
                      on platform: Platform = Platform.current,
                      which: (String) -> String? = { Platform.which($0) }) -> Archive? {
        // A tarball is tar's own format, and unzip cannot read one at all.
        guard format == .zip else { return which("tar").map { Archive(tool: .bsdtar, path: $0) } }
        switch platform {
        case .macOS, .linux, .wsl:
            return which("unzip").map { Archive(tool: .unzip, path: $0) }
        case .windows:
            return which("tar").map { Archive(tool: .bsdtar, path: $0) }
        }
    }

    /// Resolved once: nothing that answers this changes while kmap is running.
    static let current: Archive? = found()

    /// The same, for a gzip tarball.
    static let currentForTarball: Archive? = found(.tarGzip)

    /// Whether unpacking is possible at all. Several installs need it.
    static var isAvailable: Bool { current != nil }

    /// The message shown when this machine has no unpacker.
    static func missingNote(on platform: Platform = Platform.current) -> String {
        switch platform {
        case .windows:
            // Nothing to install: bsdtar is part of Windows from 10 version 1803 on.
            return t("Windows 10 version 1803 and later include tar — this one has none")
        case .macOS, .linux, .wsl:
            return t("install with: %@", Platform.installHint(.unzip))
        }
    }

    // MARK: The three things asked of it

    /// Every entry in the archive, as one blob of text to look through.
    func listing(of zip: URL) -> (executable: String, arguments: [String]) {
        switch tool {
        case .unzip: return (path, ["-l", zip.nativePath])
        case .bsdtar: return (path, ["-tf", zip.nativePath])
        }
    }

    /// One named entry, written to standard output rather than to disk.
    func read(_ entry: String, from zip: URL) -> (executable: String, arguments: [String]) {
        switch tool {
        case .unzip: return (path, ["-p", zip.nativePath, entry])
        // `-O` is what sends it to standard output; without it bsdtar writes a file.
        case .bsdtar: return (path, ["-xOf", zip.nativePath, entry])
        }
    }

    /// The archive, into a directory that already exists. `matching` narrows it to the
    /// entries whose names fit one of the shell globs, which both tools take the same way,
    /// as trailing arguments.
    func unpack(_ zip: URL, into directory: URL, matching patterns: [String] = [])
        -> (executable: String, arguments: [String]) {
        switch tool {
        case .unzip:
            // `-o` overwrites without asking; every child process gets /dev/null for stdin.
            // The patterns go before `-d`, which is unzip's own argument order.
            return (path, ["-q", "-o", zip.nativePath] + patterns
                    + ["-d", directory.nativePath])
        case .bsdtar:
            // bsdtar overwrites by default and asks nothing.
            return (path, ["-xf", zip.nativePath, "-C", directory.nativePath] + patterns)
        }
    }
}
