import Foundation

/// Every path kmap owns. Everything lives under `root` except finished maps, which go
/// to the configured output directory.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Where kmap keeps everything. `KMAP_ROOT` moves it; a test run uses `testRoot`.
    static var root: URL {
        if let told = ProcessInfo.processInfo.environment["KMAP_ROOT"], !told.isEmpty {
            return URL(
                fileURLWithPath: (told as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        // Decided here rather than per test, so no test can write the real settings.
        if isATestRun { return testRoot }
        return defaultRoot()
    }

    /// Whether this process is a test runner: an Xcode configuration variable, the
    /// `xctest` process name, or a `.xctest` binary as argument zero.
    static let isATestRun: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if ProcessInfo.processInfo.processName == "xctest" { return true }
        return CommandLine.arguments.first?.contains(".xctest") ?? false
    }()

    /// One directory per run of the suite, removed as the run ends; one that crashes leaves it.
    static let testRoot: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kmap-tests-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        atexit { try? FileManager.default.removeItem(at: Paths.testRoot) }
        return root
    }()

    /// The default root: `~/.kmap` on the Unixes, and `%LOCALAPPDATA%\kmap` on Windows,
    /// which is not copied around a domain network as the roaming profile is. The layout
    /// beneath it is the same on every platform.
    static func defaultRoot(
        _ platform: Platform = Platform.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard platform == .windows else {
            return home.appendingPathComponent(".kmap", isDirectory: true)
        }
        let local =
            environment.variable("LOCALAPPDATA", on: platform)
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("AppData/Local", isDirectory: true)
        return local.appendingPathComponent("kmap", isDirectory: true)
    }

    static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    static var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    static var indexCache: URL { cache.appendingPathComponent("geofabrik-index.json") }
    static var pbfCache: URL { cache.appendingPathComponent("pbf", isDirectory: true) }

    /// Where a region's downloaded extract is kept between builds.
    static func cachedExtract(forRegion id: String) -> URL {
        pbfCache.appendingPathComponent("\(FileTools.slugify(id)).osm.pbf")
    }
    static var polyCache: URL { cache.appendingPathComponent("poly", isDirectory: true) }
    static var hgtCache: URL { cache.appendingPathComponent("hgt", isDirectory: true) }

    static var tools: URL { root.appendingPathComponent("tools", isDirectory: true) }
    static var venv: URL { tools.appendingPathComponent("venv", isDirectory: true) }
    /// Precompiled coastline polygons. Optional; without them mkgmap derives the sea
    /// from the coastline in the extract, which is unreliable at an extract's edges.
    static var seaData: URL { tools.appendingPathComponent("sea-latest.zip") }
    /// Pre-processed administrative boundaries. Without them mkgmap infers an address's
    /// city and region, which degrades address search.
    static var boundsData: URL { tools.appendingPathComponent("bounds-latest.zip") }

    static var styles: URL { root.appendingPathComponent("styles", isDirectory: true) }
    static var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    /// Lock files that keep 2 runs from the same work.
    static var locks: URL { root.appendingPathComponent("locks", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    /// Where finished maps go unless Settings says otherwise: `~/kmap` on the Unixes,
    /// and `Documents\kmap` on Windows, where a folder in the profile root is not where
    /// anyone looks for files they made.
    static var defaultOutput: URL { defaultOutput() }

    static func defaultOutput(
        _ platform: Platform = Platform.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard platform == .windows else {
            return home.appendingPathComponent("kmap", isDirectory: true)
        }
        let profile =
            environment.variable("USERPROFILE", on: platform)
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home
        return profile.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("kmap", isDirectory: true)
    }

    /// Creates the directory tree kmap needs. Safe to call repeatedly.
    static func bootstrap() {
        for dir in [root, cache, pbfCache, hgtCache, tools, styles, work, logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Returns `url` with the home directory replaced by `~`, for display.
    static func display(_ url: URL) -> String {
        let p = url.path
        let h = home.path
        // The whole folder: /home/al is not the start of /home/alex.
        guard p == h || p.hasPrefix(h.hasSuffix("/") ? h : h + "/") else { return p }
        return "~" + p.dropFirst(h.hasSuffix("/") ? h.count - 1 : h.count)
    }

    /// Whether a typed path names 1 folder wherever kmap is started: from the root, a drive
    /// with its root, a share, or `~`. Windows' `D:foo` is relative to that drive's folder.
    static func isFullPath(_ typed: String) -> Bool {
        let path = unquoted(typed)
        if path.hasPrefix("~") { return true }
        #if os(Windows)
        let scalars = Array(path.unicodeScalars)
        if scalars.count >= 3, scalars[0].properties.isAlphabetic, scalars[1] == ":",
            scalars[2] == "\\" || scalars[2] == "/"
        {
            return true
        }
        return path.hasPrefix("\\\\") || path.hasPrefix("//")
        #else
        return path.hasPrefix("/")
        #endif
    }

    /// A typed path trimmed of edge spaces and of the quotes a copy from Windows Explorer adds.
    private static func unquoted(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
            (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// Expands a leading `~` in a typed path, and drops the quotes a path copied from
    /// Windows Explorer comes in.
    static func expand(_ path: String) -> URL {
        let trimmed = unquoted(path)
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }
        return URL(fileURLWithPath: trimmed)
    }
}
