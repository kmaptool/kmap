import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a separate module outside Apple's platforms.
import FoundationNetworking
#endif

/// Finds the external programs kmap needs, and installs the ones it can.
final class Toolchain {

    let settings: SettingsStore
    init(settings: SettingsStore) { self.settings = settings }

    // MARK: Probe cache
    //
    // A probe runs an external program to read its version, so each answer is held until
    // `invalidate` is called rather than recomputed from the render loop.

    private let cacheLock = NSLock()
    private var javaCache: JavaRuntime??
    private var kitCache: JavaRuntime??
    private var mkgmapCache: (url: URL, version: String)??
    private var pyhgtmapCache: (url: URL, version: String)??
    private var statusCache: [ToolStatus]?

    /// Discards every cached probe. Call after an install or a requested refresh.
    func invalidate() {
        cacheLock.lock()
        javaCache = nil
        kitCache = nil
        mkgmapCache = nil
        pyhgtmapCache = nil
        statusCache = nil
        cacheLock.unlock()
    }

    /// True once a probe has run.
    var hasProbed: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return statusCache != nil
    }

    private func cached<T>(_ keyPath: ReferenceWritableKeyPath<Toolchain, T??>,
                           compute: () -> T?) -> T? {
        cacheLock.lock()
        if let hit = self[keyPath: keyPath] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        // Computed outside the lock: these spawn processes.
        let value = compute()

        cacheLock.lock()
        self[keyPath: keyPath] = .some(value)
        cacheLock.unlock()
        return value
    }

    // MARK: Discovery

    /// Candidate java binaries, most preferred first. The per-platform list is in
    /// `ToolLocations`; the configured path from Settings is added here.
    private func javaCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        ToolLocations.java(configured: settings.settings.javaBinary, environment: environment)
    }

    func findJava() -> JavaRuntime? {
        cached(\.javaCache) { probeJava() }
    }

    /// The first Java that can also compile, which is not always the first Java there is:
    /// a machine can carry a runtime on its PATH and a whole JDK beside it, kmap's own
    /// among them. Nil where every Java on the machine is a runtime.
    func findJavaKit() -> JavaRuntime? {
        cached(\.kitCache) { probeJava(compilerNeeded: true) }
    }

    /// Option sets tried in order when probing a JVM, each a workaround for a platform that
    /// otherwise refuses to start one.
    private static let javaRescueOptions: [[String]] = [
        [],                                     // the ordinary case, tried first
        ["-XX:-UseCompressedClassPointers"]     // WSL1, which cannot make the reservation
    ]

    private func probeJava(compilerNeeded: Bool = false) -> JavaRuntime? {
        for candidate in javaCandidates() where FileTools.isExecutable(candidate) {
            if compilerNeeded,
               !FileTools.isExecutable(ToolLocations.companion("javac", of: candidate)) {
                continue
            }
            for options in Toolchain.javaRescueOptions {
                guard let output = ProcessRunner.capture(candidate, options + ["-version"])
                else { continue }
                // A version string is the only output that means the JVM ran: both a stub
                // launcher and a JVM that failed to initialize exit with a message instead.
                guard output.lowercased().contains("version") else { continue }
                // The first line that names the version, not the first line there is: a
                // JVM with _JAVA_OPTIONS set prints "Picked up _JAVA_OPTIONS: …" first.
                let version = output
                    .split(separator: "\n")
                    .first { $0.lowercased().contains("version") }
                    .map { String($0).trimmingCharacters(in: .whitespaces) } ?? "unknown"
                return JavaRuntime(path: candidate, version: version, options: options)
            }
        }
        return nil
    }

    /// What this machine can install unattended, resolved once per probe: detection costs
    /// eight `which` calls plus a `sudo -n` with a five-second timeout.
    struct Installability {
        let manager: PackageManager?
        let unattended: Bool

        static func detect() -> Installability {
            guard let manager = PackageManager.detect() else {
                return Installability(manager: nil, unattended: false)
            }
            return Installability(manager: manager,
                                  unattended: Privilege.forInstalling(with: manager).canRunUnattended)
        }

        /// Whether kmap can install this itself: the package manager knows it and the
        /// privilege check passed.
        func canInstall(_ what: PackageManager.Need) -> Bool {
            guard let manager, manager.packages(for: what) != nil else { return false }
            return unattended
        }

        /// Whether kmap can put this on the machine one way or another: through the
        /// package manager, or by fetching it into kmap's own directory.
        ///
        /// Only Java has the second way. It is the one a build cannot start without, and
        /// a machine with no package manager is otherwise stuck.
        func canProvide(_ what: PackageManager.Need) -> Bool {
            canInstall(what) || (what == .java && JavaDownload.isAvailable())
        }

        /// The note shown under a missing package: the manual install command where kmap
        /// cannot install it itself.
        func note(_ what: PackageManager.Need) -> String {
            guard !canProvide(what) else { return t("kmap can install this") }
            return t("install with: %@", Platform.installHint(what))
        }
    }

    /// Uncached answer, for callers outside a probe.
    static func canInstall(_ what: PackageManager.Need) -> Bool {
        Installability.detect().canInstall(what)
    }


    /// Where a patched jar is written, and the marker that says a jar carries the patch.
    static let patchedMkgmapName = "mkgmap-patched.jar"
    static let patchMarker = "kmap-patch.properties"
    /// Raise when the edits change. A jar carrying a lower number counts as unpatched, so
    /// the rebuild is offered rather than the stale patch being used.
    static let patchVersion = 17

    static var patchedMkgmapURL: URL {
        Paths.tools.appendingPathComponent("mkgmap/\(patchedMkgmapName)")
    }

    /// True when this jar carries a patch marker of at least `patchVersion`. Detected by the
    /// marker inside the jar, not by filename, so a copy or a rename still answers correctly.
    static func isPatched(_ jar: URL) -> Bool {
        patchVersion(of: jar) >= patchVersion
    }

    /// 0 for an unpatched jar, 1 for one from before the marker carried a number.
    static func patchVersion(of jar: URL) -> Int {
        guard FileTools.exists(jar), let archive = Archive.current else { return 0 }
        let list = archive.listing(of: jar)
        guard let listing = ProcessRunner.capture(list.executable, list.arguments),
              listing.contains(patchMarker) else { return 0 }
        let read = archive.read(patchMarker, from: jar)
        guard let body = ProcessRunner.capture(read.executable, read.arguments),
              let line = body.split(separator: "\n").first(where: { $0.hasPrefix("patch-version:") }),
              let version = Int(line.dropFirst("patch-version:".count)
                                    .trimmingCharacters(in: .whitespaces)) else { return 1 }
        return version
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
        // The patched jar first: it is the stock release plus four classes, and the extra
        // option is simply not passed when the patch is not wanted.
        out.append(Toolchain.patchedMkgmapURL)
        out.append(Paths.tools.appendingPathComponent("mkgmap/mkgmap.jar"))
        return out
    }

    func findMkgmap() -> (url: URL, version: String)? {
        cached(\.mkgmapCache) { probeMkgmap() }
    }

    private func probeMkgmap() -> (url: URL, version: String)? {
        guard let java = findJava() else { return nil }
        for candidate in mkgmapCandidates() where FileTools.exists(candidate) {
            let output = ProcessRunner.capture(java.path,
                                               java.command(["-jar", candidate.path, "--version"])) ?? ""
            let version = output.split(separator: "\n")
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
        let output = (ProcessRunner.capture(binary.path, ["--version"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = output.split(separator: "\n").first.map(String.init)
        return (binary, firstLine ?? "installed")
    }

    /// The first executable python3 among `ToolLocations.python()`, which searches PATH
    /// first so a version manager's copy wins over the system one.
    func findPython3() -> String? {
        ToolLocations.python().first { FileTools.isExecutable($0) }
    }

    // MARK: Aggregate status

    func status(includeContours: Bool = true) -> [ToolStatus] {
        cacheLock.lock()
        if let hit = statusCache {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let computed = probeStatus(includeContours: includeContours)

        cacheLock.lock()
        statusCache = computed
        cacheLock.unlock()
        return computed
    }

    private func probeStatus(includeContours: Bool) -> [ToolStatus] {
        let installs = Installability.detect()
        var out: [ToolStatus] = []
        let java = findJava()
        out.append(javaStatus(java, installs: installs))
        let mkgmap = findMkgmap()
        out.append(mkgmapStatus(mkgmap, java: java))
        if let mkgmap {
            out.append(patchStatus(of: mkgmap.url, canCompile: findJavaKit() != nil))
        }
        out.append(dataStatus(
            DataPack.sea, name: t("coastline data"),
            detail: t("correct sea and shorelines (optional, 344 MB)"),
            missingNote: t("without it, coastlines are derived from the extract and can flood"
                         + " inland at low zoom")))
        out.append(dataStatus(
            DataPack.bounds, name: t("boundary data"),
            detail: t("city/region for address search (optional, 2.5 GB)"),
            missingNote: t("without it, the city and region on an address are a best guess")))
        if includeContours {
            out.append(pyhgtmapStatus(installs: installs))
            if let archiver = archiverStatus(installs: installs) { out.append(archiver) }
        }
        return out
    }

    private func javaStatus(_ java: JavaRuntime?, installs: Installability) -> ToolStatus {
        // A runtime builds maps; only the seam patch needs a compiler. So a Java without
        // one is ready with a note, not a fault — and the install stays offered, since
        // every package kmap would install is a whole JDK.
        let kit = java == nil ? nil : findJavaKit()
        return ToolStatus(
            id: "java",
            name: t("Java runtime"),
            detail: t("runs mkgmap"),
            state: java == nil ? .missing : .ready,
            path: java?.path,
            version: java?.version,
            note: java == nil ? installs.note(.java)
                : kit == nil ? t("a runtime without javac — only the seam patch needs more")
                : nil,
            installable: installs.canProvide(.java) && (java == nil || kit == nil),
            moreToInstall: java != nil && kit == nil && installs.canProvide(.java))
    }

    private func mkgmapStatus(_ mkgmap: (url: URL, version: String)?,
                              java: JavaRuntime?) -> ToolStatus {
        ToolStatus(
            id: "mkgmap",
            name: "mkgmap",
            detail: t("compiles OSM data into Garmin .img"),
            state: mkgmap == nil ? .missing : .ready,
            path: mkgmap.map { Paths.display($0.url) },
            version: mkgmap?.version,
            note: java == nil ? t("needs Java first") : nil,
            installable: java != nil)
    }

    private func patchStatus(of jar: URL, canCompile: Bool) -> ToolStatus {
        let found = Toolchain.patchVersion(of: jar)
        let patched = found >= Toolchain.patchVersion
        return ToolStatus(
                id: "mkgmap-patch",
                name: t("mkgmap seam patch"),
                detail: t("experimental — hides the seams between tiles and decides what covers what"),
                state: patched ? .ready : .missing,
                path: patched ? Paths.display(jar) : nil,
                version: patched ? t("applied (v%d)", found) : nil,
                note: patched ? nil
                    : !canCompile ? t("built here from source — install a full JDK first")
                    : found > 0 ? t("an older patch — reinstall to pick up the new edits")
                    : t("without it tiles meet on a line and it shows"),
                installable: canCompile,
                isOptional: true,
                removable: patched || found > 0)
    }

    /// A downloadable data set: installed when the file is there and plausibly whole.
    private func dataStatus(_ pack: DataPack, name: String, detail: String,
                            missingNote: String) -> ToolStatus {
        let file = pack.file
        let installed = pack.isInstalled
        return ToolStatus(
            id: pack.id,
            name: name,
            detail: detail,
            state: installed ? .ready : .missing,
            path: installed ? Paths.display(file) : nil,
            version: installed ? "\(Fmt.bytes(FileTools.size(of: file)))" : nil,
            note: installed ? nil : missingNote,
            installable: true,
            isOptional: true)
    }

    /// Contour tracing and GeoTIFF reading are kmap's own, so pyhgtmap is needed only
    /// for the two sources that require an account, and only to download.
    private func pyhgtmapStatus(installs: Installability) -> ToolStatus {
        let python = findPython3()
        let pyhgtmap = findPyhgtmap()
        return ToolStatus(
                id: "pyhgtmap",
                name: "pyhgtmap",
                detail: t("adds the srtm1 and alos1 elevation sources, which need an"
                        + " account"),
                state: pyhgtmap == nil ? .missing : .ready,
                path: pyhgtmap.map { Paths.display($0.url) },
                version: pyhgtmap?.version,
                note: python == nil
                    ? t("needs python3 — %@", installs.note(.python))
                    : (pyhgtmap == nil
                       ? t("not needed for copernicus, view1 or view3") : nil),
                // Where python3 is missing but installable, kmap installs it first.
                installable: python != nil || installs.canInstall(.python),
                isOptional: true)
    }

    /// The platform's archiver, listed only while it is missing.
    private func archiverStatus(installs: Installability) -> ToolStatus? {
        guard !Archive.isAvailable else { return nil }
        return ToolStatus(
            id: "unzip",
            // The archiver this platform expects: `tar` on Windows, `unzip` elsewhere.
            name: Platform.current.usesWindowsPaths ? "tar" : "unzip",
            detail: t("unpacks everything else on this page"),
            state: .missing,
            path: nil,
            version: nil,
            note: Archive.missingNote(),
            installable: installs.canInstall(.unzip))
    }

    /// True when a build can run. The tile split is kmap's own, so only Java and mkgmap are
    /// required.
    var canBuild: Bool {
        findJava() != nil && findMkgmap() != nil
    }

    /// What a build cannot start without and this machine has not got, in the order it
    /// has to be installed: mkgmap is patched with a javac, so Java comes first.
    static func missingRequirements(in tools: [ToolStatus]) -> [ToolStatus] {
        ["java", "mkgmap"].compactMap { id in tools.first { $0.id == id && !$0.isReady } }
    }

    /// Always true: contours are traced, fetched and converted by kmap itself.
    var canBuildContours: Bool { true }

    /// True when the elevation sources requiring an account can be fetched.
    var canFetchCredentialedSources: Bool { findPyhgtmap() != nil }

    // MARK: Installation

    enum InstallError: Error, LocalizedError {
        case unsupported(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let m): return m
            case .failed(let m): return m
            }
        }
    }

    /// Every tool id `install` accepts. Listed rather than derived from `status()`, which
    /// reports only what is missing on this machine and so cannot validate a name.
    static let installableIDs = ["mkgmap", "mkgmap-patch", "pyhgtmap"]
        + DataPack.all.map(\.id) + ["java", "python", "unzip"]

}
