import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a separate module outside Apple's platforms.
import FoundationNetworking
#endif

/// Where Java, mkgmap, pyhgtmap and python are found, each probed once and cached.
extension Toolchain {
    // MARK: Discovery

    /// Candidate java binaries, most preferred first. The per-platform list is in
    /// `ToolLocations`; the configured path from Settings is added here.
    private func javaCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        ToolLocations.java(configured: configuredJava, environment: environment)
    }

    /// The Java named in the settings, as typed: a `~` or a pasted path's quotes would
    /// otherwise make it pass silently for missing.
    var configuredJava: String {
        let typed = settings.settings.javaBinary
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return Paths.expand(typed).nativePath
    }

    /// A Java gone since it was found, as one another kmap reinstalled, is looked for again.
    func findJava() -> JavaRuntime? {
        let probe = {
            self.cached(\.javaCache) {
                Self.settleInterruptedSwaps()
                return self.probeJava()
            }
        }
        guard let found = probe() else { return nil }
        guard FileTools.isExecutable(found.path) else {
            invalidate()
            return probe()
        }
        return found
    }

    /// The first Java that can also compile, which is not always the first Java there is:
    /// a machine can carry a runtime on its PATH and a whole JDK beside it, kmap's own
    /// among them. Nil where every Java on the machine is a runtime.
    func findJavaKit() -> JavaRuntime? {
        let probe = { self.cached(\.kitCache) { self.probeJava(compilerNeeded: true) } }
        guard let found = probe() else { return nil }
        guard FileTools.isExecutable(found.path) else {
            invalidate()
            return probe()
        }
        return found
    }

    /// Option sets tried in order when probing a JVM, each a workaround for a platform that
    /// otherwise refuses to start one.
    static let javaRescueOptions: [[String]] = [
        [],  // the ordinary case, tried first
        ["-XX:-UseCompressedClassPointers"]  // WSL1, which cannot make the reservation
    ]

    /// The line of `java -version` that names the version, not the first line there is:
    /// a JVM with _JAVA_OPTIONS set prints "Picked up _JAVA_OPTIONS: ..." first, and one
    /// given a deprecated option says so, "version" and all, before it. The quoted number
    /// marks the line.
    static func versionLine(of output: String) -> String {
        // Split on any line end: Windows ends its lines with CR LF, which is 1 Character.
        let lines = output.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        return lines.first { $0.lowercased().contains("version \"") } ?? "unknown"
    }

    private func probeJava(compilerNeeded: Bool = false) -> JavaRuntime? {
        let environment = ProcessInfo.processInfo.environment
        guard
            let found = javaCandidates(environment: environment).lazy
                .compactMap({ Self.runtime(at: $0, compilerNeeded: compilerNeeded) }).first
        else { return nil }
        let named = ToolLocations.namedJava(configured: configuredJava, environment: environment)
        guard !named.contains(found.path), let own = JavaDownload.installed()?.path, own != found.path else {
            return found
        }
        return Self.preferred(found: found, own: Self.runtime(at: own, compilerNeeded: compilerNeeded))
    }

    /// The Java to run: the one found first, unless kmap's own is a newer release. Only for
    /// a Java that was found, on PATH or where the system keeps one; one the user named in
    /// the settings or in JAVA_HOME is never passed over.
    static func preferred(found: JavaRuntime, own: JavaRuntime?) -> JavaRuntime {
        guard let own, let ownMajor = own.major, ownMajor > (found.major ?? 0) else { return found }
        return own
    }

    /// The JVM at `candidate`, if it runs: with no options, or with the first set of
    /// rescue options it starts on.
    static func runtime(at candidate: String, compilerNeeded: Bool) -> JavaRuntime? {
        guard FileTools.isExecutable(candidate) else { return nil }
        // javac and jar both: a folder of links can carry javac alone, and the patch needs both.
        if compilerNeeded, !JavaRuntime.isKit(at: candidate) { return nil }
        for options in javaRescueOptions {
            guard let output = ProcessProbe.capture(candidate, options + ["-version"]) else { continue }
            // A version string is the only output that means the JVM ran: both a stub
            // launcher and a JVM that failed to initialize exit with a message instead.
            // The quoted number, not the word alone: a JVM that cannot load prints
            // "version 'GLIBC_2.xx' not found".
            guard output.lowercased().contains("version \"") else { continue }
            return JavaRuntime(
                path: candidate,
                version: versionLine(of: output),
                options: options,
                isOpenJ9: output.contains("OpenJ9")
            )
        }
        return nil
    }

    var mkgmapIsPatched: Bool {
        guard let jar = findMkgmap()?.url else { return false }
        return Toolchain.isPatched(jar)
    }

    /// Candidate mkgmap jars, most preferred first. Internal because the installer asks the
    /// same question before and after a download.
    func mkgmapCandidates() -> [URL] {
        var out: [URL] = []
        let configured = settings.settings.mkgmapJar
        if !configured.isEmpty { out.append(Paths.expand(configured)) }
        // The patched jar first: it is the stock release plus 4 classes, and the extra
        // option is simply not passed when the patch is not wanted.
        out.append(Toolchain.patchedMkgmapURL)
        out.append(Paths.tools.appendingPathComponent("mkgmap/mkgmap.jar"))
        return out
    }

    func findMkgmap() -> (url: URL, version: String)? {
        cached(\.mkgmapCache) {
            Self.settleInterruptedSwaps()
            return probeMkgmap()
        }
    }

    private func probeMkgmap() -> (url: URL, version: String)? {
        guard let java = findJava() else { return nil }
        for candidate in mkgmapCandidates() where FileTools.exists(candidate) {
            // A patch compiled for a newer Java than this one: its version answers, as its
            // main class is mkgmap's own, but its patched classes would not load.
            if candidate == Toolchain.patchedMkgmapURL,
                Toolchain.isTooNew(release: Toolchain.patchState(of: candidate).release, for: java.major)
            {
                continue
            }
            let output =
                ProcessProbe.capture(
                    java.path,
                    java.command(["-jar", candidate.path, "--version"])
                ) ?? ""
            let version = output.split(whereSeparator: \.isNewline)
                .first { $0.lowercased().contains("mkgmap") }
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            if let version { return (candidate, version) }
        }
        return nil
    }

    var pyhgtmapBinary: URL { ToolLocations.inVirtualEnvironment("pyhgtmap", of: Paths.venv) }

    func findPyhgtmap() -> (url: URL, version: String)? {
        cached(\.pyhgtmapCache) { probePyhgtmap() }
    }

    private func probePyhgtmap() -> (url: URL, version: String)? {
        let binary = pyhgtmapBinary
        guard FileTools.isExecutable(binary.path) else { return nil }
        let output = (ProcessProbe.capture(binary.path, ["--version"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = output.split(separator: "\n").first.map(String.init)
        return (binary, firstLine ?? "installed")
    }

    /// The first executable python3 among `ToolLocations.python()`, which searches PATH
    /// first so a version manager's copy wins over the system one.
    func findPython3() -> String? {
        ToolLocations.python().first { FileTools.isExecutable($0) }
    }
}
