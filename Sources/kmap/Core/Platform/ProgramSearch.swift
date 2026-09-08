import Foundation

/// Program lookup by name, as the shell resolves it: what separates the entries of
/// `PATH`, and what makes a found file a program.
extension Platform {

    /// Returns the search path as a list of directories, with a login shell's usual
    /// directories appended for launchers that start kmap with a minimal `PATH`.
    static func searchPath(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                           on platform: Platform = Platform.current) -> [String] {
        let raw = environment.variable("PATH", on: platform) ?? ""
        // Windows entries begin with a drive letter, so they are separated by semicolons.
        let separator: Character = platform.usesWindowsPaths ? ";" : ":"
        var out = raw.split(separator: separator).map(String.init).filter { !$0.isEmpty }
        let systemRoot = environment.variable("SystemRoot", on: platform) ?? #"C:\Windows"#
        let fallbacks = platform.usesWindowsPaths
            ? [systemRoot + #"\System32"#, systemRoot]
            : ["/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/bin"]
        for fallback in fallbacks where !out.contains(fallback) {
            out.append(fallback)
        }
        return out
    }

    /// Returns the suffixes that make a name a program: none on Unix, where the execute
    /// bit decides, and `PATHEXT` on Windows, where the extension does.
    static func executableSuffixes(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                   on platform: Platform = Platform.current) -> [String] {
        guard platform.usesWindowsPaths else { return [""] }
        let raw = environment.variable("PATHEXT", on: platform) ?? ".COM;.EXE;.BAT;.CMD"
        let listed = raw.split(separator: ";").map { String($0).lowercased() }
            .filter { !$0.isEmpty }
        // Empty first, so a name given with its extension is found as written.
        return [""] + listed
    }

    /// Returns the first `name` on the search path, as `which` would find it, or nil.
    static func which(_ name: String,
                      environment: [String: String] = ProcessInfo.processInfo.environment,
                      on platform: Platform = Platform.current,
                      exists: (String) -> Bool = { FileTools.isExecutable($0) })
        -> String? {
        let suffixes = executableSuffixes(environment, on: platform)
        // A name that is already a path is used as given; backslashes separate on
        // Windows as slashes do elsewhere.
        if name.contains("/") || (platform.usesWindowsPaths && name.contains("\\")) {
            return suffixes.lazy.map { name + $0 }.first(where: exists)
        }
        let separator = platform.usesWindowsPaths ? "\\" : "/"
        for directory in searchPath(environment, on: platform) {
            // Suffixes vary fastest, matching the shell's resolution order.
            let stem = directory.hasSuffix(separator) ? directory + name
                                                      : directory + separator + name
            if let hit = suffixes.lazy.map({ stem + $0 }).first(where: exists) { return hit }
        }
        return nil
    }
}
