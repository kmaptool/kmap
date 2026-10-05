import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a module of its own outside Apple's platforms.
import FoundationNetworking
#endif

/// Getting the missing pieces, and putting them back.
///
/// Installs the programs kmap needs but does not ship: a JVM, mkgmap, splitter, pyhgtmap.
/// Everything lands under the kmap directory; nothing is written outside it except through
/// the machine's package manager.
extension Toolchain {
    /// Takes one tool back off. Only the patch can be removed; deleting the jar kmap built
    /// leaves the stock mkgmap beside it to take over on the next build.
    func remove(_ id: String, log: Log) throws {
        defer { invalidate() }
        switch id {
        case "java":
            guard FileTools.exists(JavaDownload.home) else {
                throw InstallError.failed(t("kmap installed no Java of its own"))
            }
            log.step(t("removing the Java kmap installed"))
            FileTools.removeIfPresent(JavaDownload.home)
            log.ok(t("removed"))

        case "mkgmap-patch":
            let jar = Toolchain.patchedMkgmapURL
            guard FileTools.exists(jar) else {
                throw InstallError.failed(t("the patched mkgmap is not there"))
            }
            log.step(t("removing the patched mkgmap"))
            FileTools.removeIfPresent(jar)
            JavaWarmStart.forgetAll(for: jar)
            log.ok(t("removed — builds will use the stock mkgmap"))
        default:
            throw InstallError.unsupported(t("%@ cannot be removed", id))
        }
    }

    /// The command an install would run as root, or nil where it needs none. Returned only
    /// where sudo would not ask for a password, so the screen can show what one keystroke
    /// would change across the machine.
    func rootInstallCommand(for id: String) -> String? {
        let need: PackageManager.Need
        switch id {
        case "java": need = .java
        case "python": need = .python
        case "unzip": need = .unzip
        default: return nil
        }
        guard let manager = PackageManager.detect() else { return nil }
        let privilege = Privilege.forInstalling(with: manager)
        guard privilege == .passwordlessSudo else { return nil }
        return manager.spokenCommand(for: need, privilege: privilege)
    }

    /// What an install fetches on its own when it is not there: the patch is compiled
    /// against mkgmap with a JDK, mkgmap arrives as a zip, pyhgtmap is a Python package.
    /// Two installs that overlap this way would fetch the same thing into the same place.
    static func prerequisites(of id: String) -> [String] {
        switch id {
        case "mkgmap-patch": return ["java", "mkgmap"]
        case "mkgmap": return ["unzip"]
        case "pyhgtmap": return ["python"]
        default: return []
        }
    }

    /// Whether two installs must not run at once: either fetches what the other is.
    static func overlap(_ id: String, _ other: String) -> Bool {
        prerequisites(of: id).contains(other) || prerequisites(of: other).contains(id)
    }

    /// What an install killed part-way left in the tools folder: its unpacking folders and
    /// the JDK archive. Only those an hour old, so another kmap installing now keeps its own.
    static func removeAbandonedStaging(in tools: URL = Paths.tools, now: Date = Date()) {
        let stagingPrefixes = ["jdk-unpack-", "unpack-", "mkgmap-patch-", "OpenJDK"]
        let entries = (try? FileManager.default.contentsOfDirectory(at: tools, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            guard stagingPrefixes.contains(where: name.hasPrefix),
                let changed = FileTools.modified(of: entry), now.timeIntervalSince(changed) > 3600
            else { continue }
            FileTools.removeIfPresent(entry)
        }
    }

    /// - Parameter downloading: fetch into kmap's own directory even where the machine's
    ///   package manager could install it. Only Java can be had both ways.
    func install(
        _ id: String,
        log: Log,
        runner: ProcessRunner,
        downloading: Bool = false,
        progress: InstallProgress? = nil
    ) async throws {
        defer { invalidate(); progress?.finish() }
        Self.removeAbandonedStaging()
        switch id {
        case "mkgmap":
            try await installMkgmap(log: log, runner: runner, progress: progress)

        case "mkgmap-patch":
            try await patchMkgmap(log: log, runner: runner, progress: progress)

        case "pyhgtmap":
            try await installPyhgtmap(log: log, runner: runner, progress: progress)

        case "sea":
            try await installDataPack(
                .sea,
                log: log,
                progress: progress,
                name: t("precompiled coastline polygons (~344 MB)")
            )

        case "bounds":
            try await installDataPack(
                .bounds,
                log: log,
                progress: progress,
                name: t("administrative boundaries (~2.5 GB)")
            )

        case "java":
            // The machine's own package manager first, where it can do it without a
            // password; otherwise kmap fetches a JDK into its own directory.
            if !downloading, Toolchain.Installability.detect().canInstall(.java) {
                try await installSystemPackage(
                    .java,
                    log: log,
                    runner: runner,
                    progress: progress
                )
            } else {
                try await installOwnJava(log: log, runner: runner, progress: progress)
            }

        case "python":
            try await installSystemPackage(
                .python,
                log: log,
                runner: runner,
                progress: progress
            )

        case "unzip":
            try await installSystemPackage(
                .unzip,
                log: log,
                runner: runner,
                progress: progress
            )

        default:
            throw InstallError.unsupported(t("nothing known about \"%@\"", id))
        }
    }
}
