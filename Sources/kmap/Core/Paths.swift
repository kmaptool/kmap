import Foundation

/// Every path kmap owns. Everything lives under `root` except finished maps, which go
/// to the configured output directory.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Where kmap keeps everything. `KMAP_ROOT` moves it; a test run uses `testRoot`.
    static var root: URL {
        if let told = ProcessInfo.processInfo.environment["KMAP_ROOT"], !told.isEmpty {
            return URL(fileURLWithPath: (told as NSString).expandingTildeInPath,
                       isDirectory: true)
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

    /// One directory per run of the suite, so nothing survives into the next run.
    static let testRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmap-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)

    /// The default root: `~/.kmap` on the Unixes, and `%LOCALAPPDATA%\kmap` on Windows,
    /// which is not copied around a domain network as the roaming profile is. The layout
    /// beneath it is the same on every platform.
    static func defaultRoot(_ platform: Platform = Platform.current,
                            environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL {
        guard platform == .windows else {
            return home.appendingPathComponent(".kmap", isDirectory: true)
        }
        let local = environment.variable("LOCALAPPDATA", on: platform)
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("AppData/Local", isDirectory: true)
        return local.appendingPathComponent("kmap", isDirectory: true)
    }

    static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    static var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    static var indexCache: URL { cache.appendingPathComponent("geofabrik-index.json") }
    static var pbfCache: URL { cache.appendingPathComponent("pbf", isDirectory: true) }
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
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    /// Where finished maps go unless Settings says otherwise: `~/kmap` on the Unixes,
    /// and `Documents\kmap` on Windows, where a folder in the profile root is not where
    /// anyone looks for files they made.
    static var defaultOutput: URL { defaultOutput() }

    static func defaultOutput(_ platform: Platform = Platform.current,
                              environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL {
        guard platform == .windows else {
            return home.appendingPathComponent("kmap", isDirectory: true)
        }
        let profile = environment.variable("USERPROFILE", on: platform)
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
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }

    /// Expands a leading `~` in a typed path.
    static func expand(_ path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }
        return URL(fileURLWithPath: trimmed)
    }
}


extension URL {
    /// Whether two URLs name the same file, resolving symlinks first. `==` alone treats
    /// two spellings of one path as different.
    func sameFile(as other: URL) -> Bool {
        resolvingSymlinksInPath().standardizedFileURL
            == other.resolvingSymlinksInPath().standardizedFileURL
    }
}
