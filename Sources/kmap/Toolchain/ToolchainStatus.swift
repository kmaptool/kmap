import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a separate module outside Apple's platforms.
import FoundationNetworking
#endif

/// What the setup screen and `kmap doctor` show: a row per tool, and whether a build can run.
extension Toolchain {
    /// What this machine can install unattended, resolved once per probe: detection costs
    /// 8 `which` calls plus a `sudo -n` with a 5-second timeout.
    struct Installability {
        let manager: PackageManager?
        let unattended: Bool

        static func detect() -> Installability {
            guard let manager = PackageManager.detect() else {
                return Installability(manager: nil, unattended: false)
            }
            return Installability(
                manager: manager,
                unattended: Privilege.forInstalling(with: manager).canRunUnattended
            )
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

    // MARK: Aggregate status

    func status() -> [ToolStatus] {
        cacheLock.lock()
        if let hit = statusCache {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let computed = probeStatus()

        cacheLock.lock()
        statusCache = computed
        cacheLock.unlock()
        return computed
    }

    private func probeStatus() -> [ToolStatus] {
        let installs = Installability.detect()
        var out: [ToolStatus] = []
        let java = findJava()
        out.append(javaStatus(java, installs: installs))
        let mkgmap = findMkgmap()
        out.append(mkgmapStatus(mkgmap, java: java))
        if let mkgmap {
            // A patch too new for this Java is passed over for the stock jar, and is still
            // the one to report.
            let patched = Toolchain.patchedMkgmapURL
            let skipped = Toolchain.patchState(of: patched)
            let jar =
                skipped.version > 0 && Toolchain.isTooNew(release: skipped.release, for: java?.major)
                ? patched : mkgmap.url
            out.append(patchStatus(of: jar, runtime: java?.major, canCompile: findJavaKit() != nil))
        }
        out.append(
            dataStatus(
                DataPack.sea,
                name: t("coastline data"),
                detail: t("correct sea and shorelines (optional, 344 MB)"),
                missingNote: t(
                    "without it, coastlines are derived from the extract and can flood"
                        + " inland at low zoom"
                )
            )
        )
        out.append(
            dataStatus(
                DataPack.bounds,
                name: t("boundary data"),
                detail: t("city/region for address search (optional, 2.5 GB)"),
                missingNote: t("without it, the city and region on an address are a best guess")
            )
        )
        out.append(pyhgtmapStatus(installs: installs))
        if let archiver = archiverStatus(installs: installs) { out.append(archiver) }
        return out
    }

    private func javaStatus(_ java: JavaRuntime?, installs: Installability) -> ToolStatus {
        // A runtime builds maps; only the seam patch needs a compiler. So a Java without
        // one is ready with a note, not a fault, and the install stays offered, since
        // every package kmap would install is a whole JDK.
        let kit = java == nil ? nil : findJavaKit()
        return ToolStatus(
            id: "java",
            name: t("Java runtime"),
            detail: t("runs mkgmap"),
            state: java == nil ? .missing : .ready,
            path: java?.path,
            version: java?.version,
            note: java == nil
                ? installs.note(.java)
                : kit == nil
                    ? t("a runtime without javac — only the seam patch needs more")
                    : nil,
            installable: installs.canProvide(.java) && (java == nil || kit == nil),
            moreToInstall: java != nil && kit == nil && installs.canProvide(.java)
        )
    }

    private func mkgmapStatus(
        _ mkgmap: (url: URL, version: String)?,
        java: JavaRuntime?
    ) -> ToolStatus {
        ToolStatus(
            id: "mkgmap",
            name: "mkgmap",
            detail: t("compiles OSM data into Garmin .img"),
            state: mkgmap == nil ? .missing : .ready,
            path: mkgmap.map { Paths.display($0.url) },
            version: mkgmap?.version,
            note: java == nil ? t("needs Java first") : nil,
            installable: java != nil
        )
    }

    private func patchStatus(of jar: URL, runtime: Int?, canCompile: Bool) -> ToolStatus {
        let state = Toolchain.patchState(of: jar)
        let found = state.version
        let tooNew = found > 0 && Toolchain.isTooNew(release: state.release, for: runtime)
        let patched = found >= Toolchain.patchVersion && !tooNew
        return ToolStatus(
            id: "mkgmap-patch",
            name: t("mkgmap seam patch"),
            detail: t("experimental — hides the seams between tiles and decides what covers what"),
            state: patched ? .ready : .missing,
            path: patched ? Paths.display(jar) : nil,
            version: patched ? t("applied (v%d)", found) : nil,
            note: patched
                ? nil
                : !canCompile
                    ? t("built here from source — install a full JDK first")
                    : tooNew
                        ? t("built for a newer Java — kmap rebuilds it at the next start or build")
                        : found > 0
                            ? t("an older patch — kmap rebuilds it at the next start or build")
                            : t("without it tiles meet on a line and it shows"),
            installable: canCompile,
            isOptional: true,
            removable: patched || found > 0
        )
    }

    /// A downloadable data set: installed when the file is there and plausibly whole.
    private func dataStatus(
        _ pack: DataPack,
        name: String,
        detail: String,
        missingNote: String
    ) -> ToolStatus {
        let file = pack.file
        let installed = pack.isInstalled
        return ToolStatus(
            id: pack.id,
            name: name,
            detail: detail,
            state: installed ? .ready : .missing,
            path: installed ? Paths.display(file) : nil,
            // The pack itself, where it is reached by a link.
            version: installed ? "\(Fmt.bytes(FileTools.size(of: FileTools.resolvingLinks(file))))" : nil,
            note: installed ? nil : missingNote,
            installable: true,
            isOptional: true
        )
    }

    /// Contour tracing and GeoTIFF reading are kmap's own, so pyhgtmap is needed only
    /// for the 2 sources that require an account, and only to download.
    private func pyhgtmapStatus(installs: Installability) -> ToolStatus {
        let python = findPython3()
        let pyhgtmap = findPyhgtmap()
        return ToolStatus(
            id: "pyhgtmap",
            name: "pyhgtmap",
            detail: t(
                "adds the srtm1 and alos1 elevation sources, which need an"
                    + " account"
            ),
            state: pyhgtmap == nil ? .missing : .ready,
            path: pyhgtmap.map { Paths.display($0.url) },
            version: pyhgtmap?.version,
            note: python == nil
                ? t("needs python3 — %@", installs.note(.python))
                : (pyhgtmap == nil
                    ? t("not needed for copernicus, fabdem, gedtm, view1 or view3") : nil),
            // Where python3 is missing but installable, kmap installs it first.
            installable: python != nil || installs.canInstall(.python),
            isOptional: true
        )
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
            installable: installs.canInstall(.unzip)
        )
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
}
