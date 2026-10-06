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
        // Not while another kmap rebuilds the patch: it would put it back.
        var mkgmapHeld: HeldLock?
        if id == "mkgmap-patch" {
            Paths.ensure(Paths.locks)
            mkgmapHeld = HeldLock(trying: Toolchain.mkgmapLock)
            guard mkgmapHeld != nil else {
                throw InstallError.failed(t("mkgmap is being installed or rebuilt — wait for it to end"))
            }
        }
        try withExtendedLifetime(mkgmapHeld) {
            // Asked from the interface, which must not stop drawing while a swap is waited out.
            try Self.whileUnused(waiting: false) { try Self.swapping { try removeOwn(id, log: log) } }
        }
    }

    private func removeOwn(_ id: String, log: Log) throws {
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

    /// What a killed install left in the tools folder, an hour old so another kmap
    /// installing now keeps its own.
    static func removeAbandonedStaging(in tools: URL = Paths.tools, now: Date = Date()) {
        settleInterruptedSwaps(in: tools)
        let stagingPrefixes = ["jdk-unpack-", "unpack-", "mkgmap-patch-", "OpenJDK"]
        let entries = (try? FileManager.default.contentsOfDirectory(at: tools, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            guard stagingPrefixes.contains(where: name.hasPrefix) || name == "mkgmap.new",
                let changed = FileTools.modified(of: entry), now.timeIntervalSince(changed) > 3600
            else { continue }
            FileTools.removeIfPresent(entry)
        }
    }

    /// A tool an install killed midway set aside goes back, so the tool is found again;
    /// see `FileTools.replace`. The patched jar is swapped inside mkgmap's own folder.
    static func settleInterruptedSwaps(in tools: URL = Paths.tools) {
        swapping {
            FileTools.settleSetAside(in: tools)
            FileTools.settleSetAside(in: tools.appendingPathComponent("mkgmap", isDirectory: true))
        }
    }

    /// Held shared by every build for its whole run: a tool swapped under one fails it
    /// midway, and Windows moves no file a program has open.
    static var inUseLock: URL { Paths.locks.appendingPathComponent("tools-in-use.lock") }

    /// Refuses while a build runs, as one that replaces or removes kmap's Java or mkgmap.
    static func refuseWhileBuilding() throws {
        try whileUnused {}
    }

    /// Runs `body` with no build running, and none starting until it is done.
    ///
    /// - Parameter waiting: false to refuse at once where another install's swap is under
    ///   way too, rather than wait it out.
    static func whileUnused<T>(waiting: Bool = true, _ body: () throws -> T) throws -> T {
        Paths.ensure(Paths.locks)
        // Another install's swap holds it a moment, with the swap lock: waited out. A build
        // holds it for its whole run, without: refused at once, after a 2nd look for a swap
        // about to take its lock.
        let deadline = Date().addingTimeInterval(waiting ? swapWait : 0)
        var held = HeldLock(trying: inUseLock)
        var looks = waiting ? 0 : 2
        if held == nil, !waiting, HeldLock(trying: swapsLock) == nil {
            throw InstallError.failed(t("another install is putting its tools in place — try again in a moment"))
        }
        while held == nil, Date() < deadline, looks < 2 || HeldLock(trying: swapsLock) == nil {
            looks += 1
            Thread.sleep(forTimeInterval: 0.25)
            held = HeldLock(trying: inUseLock)
        }
        guard let held else {
            throw InstallError.failed(t("a build or a patch rebuild is using these tools — try again once it ends"))
        }
        return try withExtendedLifetime(held) { try body() }
    }

    /// The longest another install's swap is waited for: removing a JDK on Windows is slow.
    private static let swapWait: TimeInterval = 120

    /// Puts `fresh` in the place of a tool no build is running. Where none is there yet no
    /// build runs it, and one that fetches its first mkgmap goes ahead.
    static func replaceUnused(_ destination: URL, with fresh: URL) throws {
        guard FileTools.exists(destination) else {
            return try swapping { try FileTools.replace(destination, with: fresh) }
        }
        try whileUnused { try swapping { try FileTools.replace(destination, with: fresh) } }
    }

    /// Tool swaps and their settling, 1 at a time across every kmap.
    static func swapping<T>(_ body: () throws -> T) rethrows -> T {
        Paths.ensure(Paths.locks)
        return try FileLock.holding(swapsLock, body)
    }

    private static var swapsLock: URL { Paths.locks.appendingPathComponent("tool-swaps.lock") }

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
        // Said before a download, not after it, and only where a tool is there to replace.
        let ownJava = id == "java" && (downloading || !Toolchain.Installability.detect().canInstall(.java))
        let replaced: URL? =
            switch id {
            case "mkgmap": Paths.tools.appendingPathComponent("mkgmap", isDirectory: true)
            case "mkgmap-patch": Toolchain.patchedMkgmapURL
            default: ownJava ? JavaDownload.home : nil
            }
        if let replaced, FileTools.exists(replaced) { try Self.refuseWhileBuilding() }
        // mkgmap and its patch share a download and a folder with another kmap's.
        var mkgmapHeld: HeldLock?
        if id == "mkgmap" || id == "mkgmap-patch" {
            Paths.ensure(Paths.locks)
            mkgmapHeld = HeldLock(trying: Toolchain.mkgmapLock)
            guard mkgmapHeld != nil else {
                throw InstallError.failed(t("mkgmap is being installed or rebuilt — wait for it to end"))
            }
        }
        defer { withExtendedLifetime(mkgmapHeld) {} }
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
