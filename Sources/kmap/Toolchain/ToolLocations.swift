import Foundation

/// Where each platform keeps the programs kmap does not ship: a JVM and a Python 3.
///
/// Pure: given an environment and a directory listing, these return what to try and in what
/// order without touching the machine, so any platform's answers can be tested from any
/// other. The `platform`, `environment`, `which` and `contents` parameters exist for that.
enum ToolLocations {

    // MARK: Java

    /// Candidate `java` binaries, most preferred first: the configured path, then what the
    /// installers record, then PATH — which is where a version manager's JDK is found —
    /// then the one kmap downloaded for itself, then the well-known locations.
    ///
    /// kmap's own copy comes after PATH so that a Java the user installed deliberately
    /// wins, and before the well-known locations so that it beats a guess.
    static func java(on platform: Platform = Platform.current,
                     configured: String = "",
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     which: (String, [String: String]) -> String? = {
                         Platform.which($0, environment: $1)
                     },
                     contents: (String) -> [String] = Self.contentsOfDirectory,
                     ownJava: (Platform) -> String? = { JavaDownload.installed(on: $0)?.path },
                     macJavaHome: () -> String? = Self.macJavaHome) -> [String] {
        var out: [String] = []
        if !configured.isEmpty { out.append(configured) }

        // Set by JDK installers and version managers.
        if let home = environment.variable("JAVA_HOME", on: platform), !home.isEmpty {
            out.append(javaUnder(home, on: platform))
        }
        if platform == .macOS, let home = macJavaHome() {
            out.append(javaUnder(home, on: platform))
        }
        if let onPath = which("java", environment) { out.append(onPath) }
        if let own = ownJava(platform) { out.append(own) }

        switch platform {
        case .macOS, .linux, .wsl:
            out += ["/opt/homebrew/opt/openjdk/bin/java",
                    "/usr/local/opt/openjdk/bin/java",
                    "/opt/homebrew/bin/java",
                    "/usr/lib/jvm/default-java/bin/java",
                    "/usr/bin/java"]
        case .windows:
            // Each vendor installs into a version-named folder, so the parents are listed
            // and their contents sorted newest first.
            for parent in javaParents(environment) {
                for jdk in jdkFolders(in: parent, contents: contents) {
                    out.append(javaUnder(parent + #"\"# + jdk, on: platform))
                }
            }
        }
        return out
    }

    /// `<home>/bin/java`, or `<home>\bin\java.exe` on Windows.
    private static func javaUnder(_ home: String, on platform: Platform) -> String {
        guard platform.usesWindowsPaths else { return home + "/bin/java" }
        let trimmed = home.hasSuffix(#"\"#) ? String(home.dropLast()) : home
        return trimmed + #"\bin\java.exe"#
    }

    /// The folders Windows JDKs are installed under, in the order they are worth trying.
    private static func javaParents(_ environment: [String: String]) -> [String] {
        let programFiles = environment.variable("ProgramFiles", on: .windows)
            ?? #"C:\Program Files"#
        var out = [
            // Where winget installs the JDK kmap asks it for.
            programFiles + #"\Microsoft"#,
            programFiles + #"\Eclipse Adoptium"#,
            programFiles + #"\Java"#,
            programFiles + #"\Amazon Corretto"#,
            programFiles + #"\Zulu"#
        ]
        // Per-user installs, which is where an installer run without administrator rights
        // writes.
        if let local = environment.variable("LOCALAPPDATA", on: .windows), !local.isEmpty {
            out.append(local + #"\Programs\Eclipse Adoptium"#)
            out.append(local + #"\Programs\Microsoft"#)
        }
        return out
    }

    /// The JDK folders inside `parent`, newest first.
    private static func jdkFolders(in parent: String,
                                   contents: (String) -> [String]) -> [String] {
        contents(parent)
            .filter { name in
                let lower = name.lowercased()
                return lower.hasPrefix("jdk") || lower.hasPrefix("jre") || lower.hasPrefix("zulu")
            }
            .sorted { newer($0, than: $1) }
    }

    /// Whether `one` names a newer version than `other`, comparing the numbers in the name
    /// componentwise: a textual sort puts `jdk-9` after `jdk-21`.
    static func newer(_ one: String, than other: String) -> Bool {
        let left = numbers(in: one), right = numbers(in: other)
        for (a, b) in zip(left, right) where a != b { return a > b }
        if left.count != right.count { return left.count > right.count }
        return one > other
    }

    private static func numbers(in name: String) -> [Int] {
        name.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    /// A tool beside `java` in the same JDK, such as `javac` or `jar`, with the `.exe`
    /// suffix on Windows. Taken from the JDK directory rather than PATH, since javac and jar
    /// must come from the same JDK as java.
    static func companion(_ name: String, of java: String,
                          on platform: Platform = Platform.current) -> String {
        let file = platform.usesWindowsPaths ? name + ".exe" : name
        // Split textually, not through a URL: a URL built on one platform does not know
        // another platform's separators.
        let separators: Set<Character> = platform.usesWindowsPaths ? ["\\", "/"] : ["/"]
        guard let cut = java.lastIndex(where: { separators.contains($0) }) else { return file }
        return java[java.startIndex...cut] + file
    }

    // MARK: Python

    /// Candidate `python3` binaries, most preferred first. PATH comes first, so a version
    /// manager's copy wins over the system one.
    static func python(on platform: Platform = Platform.current,
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       which: (String, [String: String]) -> String? = {
                           Platform.which($0, environment: $1)
                       },
                       contents: (String) -> [String] = Self.contentsOfDirectory) -> [String] {
        switch platform {
        case .macOS, .linux, .wsl:
            var out: [String] = []
            if let onPath = which("python3", environment) { out.append(onPath) }
            out += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            return out

        case .windows:
            var out: [String] = []
            // `python3` first even here: inside a virtual environment or a Cygwin or MSYS
            // install it exists and is unambiguous.
            for name in ["python3", "python"] {
                if let onPath = which(name, environment) { out.append(onPath) }
            }
            for parent in pythonParents(environment) {
                for folder in contents(parent).filter({ $0.lowercased().hasPrefix("python") })
                    .sorted(by: { newer($0, than: $1) }) {
                    out.append(parent + #"\"# + folder + #"\python.exe"#)
                }
            }
            return out.filter { !isAppExecutionAlias($0) }
        }
    }

    /// The folders a Windows Python installs into.
    private static func pythonParents(_ environment: [String: String]) -> [String] {
        var out: [String] = []
        if let local = environment.variable("LOCALAPPDATA", on: .windows), !local.isEmpty {
            // The installer's own default: a per-user install.
            out.append(local + #"\Programs\Python"#)
        }
        out.append(environment.variable("ProgramFiles", on: .windows) ?? #"C:\Program Files"#)
        return out
    }

    /// Whether the path is a Windows app execution alias: a zero-byte stub under
    /// `WindowsApps` that opens the Microsoft Store instead of running. On PATH by default.
    static func isAppExecutionAlias(_ path: String) -> Bool {
        path.lowercased().contains(#"\windowsapps\"#)
    }

    // MARK: Inside a virtual environment

    /// A program inside a Python virtual environment: `venv/bin/<name>` on the Unixes,
    /// `venv\Scripts\<name>.exe` on Windows, as `python -m venv` writes them.
    static func inVirtualEnvironment(_ name: String, of venv: URL,
                                     on platform: Platform = Platform.current) -> URL {
        guard platform.usesWindowsPaths else {
            return venv.appendingPathComponent("bin/" + name)
        }
        return venv.appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent(name + ".exe")
    }

    // MARK: Java's own notion of a path list

    /// The separator between `-classpath` entries, matching Java's `File.pathSeparator`:
    /// a semicolon on Windows, a colon elsewhere.
    static func classpathSeparator(on platform: Platform = Platform.current) -> String {
        platform.usesWindowsPaths ? ";" : ":"
    }

    // MARK: The machine, asked

    private static func contentsOfDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// The JDK home reported by the macOS `java_home` shim, or nil where it reports none.
    private static func macJavaHome() -> String? {
        guard let home = ProcessRunner.capture("/usr/libexec/java_home", [])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !home.isEmpty, !home.lowercased().contains("unable to") else { return nil }
        return home
    }
}
