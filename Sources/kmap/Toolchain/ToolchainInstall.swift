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

    /// - Parameter downloading: fetch into kmap's own directory even where the machine's
    ///   package manager could install it. Only Java can be had both ways.
    func install(_ id: String, log: Log, runner: ProcessRunner,
                 downloading: Bool = false,
                 progress: InstallProgress? = nil) async throws {
        defer { invalidate(); progress?.finish() }
        switch id {
        case "mkgmap":
            try await installMkgmap(log: log, runner: runner, progress: progress)

        case "mkgmap-patch":
            try await patchMkgmap(log: log, runner: runner, progress: progress)

        case "pyhgtmap":
            try await installPyhgtmap(log: log, runner: runner, progress: progress)


        case "sea":
            try await installDataPack(.sea, log: log, progress: progress,
                                      name: t("precompiled coastline polygons (~344 MB)"))

        case "bounds":
            try await installDataPack(
                .bounds, log: log, progress: progress,
                name: t("administrative boundaries (~2.5 GB)"))

        case "java":
            // The machine's own package manager first, where it can do it without a
            // password; otherwise kmap fetches a JDK into its own directory.
            if !downloading, Toolchain.Installability.detect().canInstall(.java) {
                try await installSystemPackage(.java, log: log, runner: runner,
                                               progress: progress)
            } else {
                try await installOwnJava(log: log, runner: runner, progress: progress)
            }

        case "python":
            try await installSystemPackage(.python, log: log, runner: runner,
                                           progress: progress)

        case "unzip":
            try await installSystemPackage(.unzip, log: log, runner: runner,
                                           progress: progress)

        default:
            throw InstallError.unsupported(t("nothing known about \"%@\"", id))
        }
    }

    /// Downloads a JDK into kmap's own directory, for a machine with no package manager
    /// that can install one.
    ///
    /// The archive is checked against the checksum Adoptium publishes for it before
    /// anything is unpacked, and the unpacked tree replaces any earlier one only once a
    /// `java` inside it has been found and has run.
    private func installOwnJava(log: Log, runner: ProcessRunner,
                                progress: InstallProgress? = nil) async throws {
        guard JavaDownload.isAvailable() else { throw JavaDownload.Trouble.unsupportedMachine }

        progress?.step(t("looking up the current Java %d build", JavaDownload.feature))
        log.step(t("looking up the current Java %d build", JavaDownload.feature))
        guard let assets = JavaDownload.assetsURL() else {
            throw JavaDownload.Trouble.unsupportedMachine
        }
        // Named explicitly: the API refuses a request that sends no User-Agent, and
        // what URLSession writes there differs between platforms.
        var request = URLRequest(url: assets)
        request.setValue("kmap/\(Version.number)", forHTTPHeaderField: "User-Agent")
        let (listing, _) = try await URLSession.shared.data(for: request)
        let release = try JavaDownload.release(fromAssets: listing)
        log.append(t("%1$@ — %2$@", release.name, Fmt.bytes(Int64(release.bytes))))

        Paths.ensure(Paths.tools)
        let archiveFile = Paths.tools.appendingPathComponent(release.fileName)
        defer { FileTools.removeIfPresent(archiveFile) }
        let downloader = Downloader(log: log)
        progress?.downloading(t("downloading %@", release.name), downloader.progress)
        try await downloader.download(url: release.link, to: archiveFile, connections: 4)

        progress?.step(t("checking the download"))
        log.step(t("checking the download"))
        let digest = SHA256.hex(ofFileAt: archiveFile) ?? ""
        guard digest == release.checksum else {
            throw JavaDownload.Trouble.badChecksum(expected: release.checksum, got: digest)
        }

        // Unpacked beside the destination, so a failure part-way leaves the JDK that is
        // already there working.
        let staging = Paths.tools.appendingPathComponent("jdk-unpack-\(UUID().uuidString.prefix(8))")
        Paths.ensure(staging)
        defer { FileTools.removeIfPresent(staging) }

        let format: Archive.Format = release.fileName.hasSuffix(".zip") ? .zip : .tarGzip
        guard let archive = Archive.found(format) else {
            throw InstallError.unsupported(Archive.missingNote())
        }
        progress?.step(t("unpacking"))
        log.step(t("unpacking"))
        let unpack = archive.unpack(archiveFile, into: staging)
        try await runner.run(unpack.executable, unpack.arguments) { line in log.output(line) }

        guard JavaDownload.javaBinary(under: staging) != nil else {
            throw JavaDownload.Trouble.noJavaInside
        }
        FileTools.removeIfPresent(JavaDownload.home)
        Paths.ensure(JavaDownload.home.deletingLastPathComponent())
        try FileManager.default.moveItem(at: staging, to: JavaDownload.home)

        invalidate()
        guard let java = findJava() else { throw JavaDownload.Trouble.noJavaInside }
        log.ok(t("Java ready — %@", java.version))
    }

    /// Asks the machine's own package manager for something kmap does not ship.
    ///
    /// Refuses before running anything where root is needed and sudo would ask for a
    /// password: children get /dev/null for stdin, so the prompt would hang unseen.
    private func installSystemPackage(_ what: PackageManager.Need,
                                      log: Log, runner: ProcessRunner,
                                      progress: InstallProgress? = nil) async throws {
        guard let manager = PackageManager.detect() else {
            throw InstallError.unsupported(
                t("no package manager kmap knows was found — install %@ by hand",
                  what.spokenName))
        }
        let privilege = Privilege.forInstalling(with: manager)
        guard let command = manager.command(for: what, privilege: privilege) else {
            throw InstallError.unsupported(
                t("%1$@ has no name for %2$@ that kmap knows",
                  manager.spokenName, what.spokenName))
        }
        guard command.runnable else {
            // A root install where sudo wants a password: report the exact command instead.
            throw InstallError.unsupported(
                t("this needs a root password, which kmap cannot ask for from here. Run:  %@",
                  manager.spokenCommand(for: what, privilege: privilege) ?? ""))
        }

        progress?.step(t("installing %1$@ with %2$@", what.spokenName, manager.spokenName))
        log.step(t("installing %1$@ with %2$@", what.spokenName, manager.spokenName))
        guard let executable = Platform.which(command.executable) else {
            throw InstallError.unsupported(t("%@ is not where it said it was",
                                             command.executable))
        }
        // apt refuses to run without this when there is no terminal to ask questions on.
        try await runner.run(executable, command.arguments,
                             environment: ["DEBIAN_FRONTEND": "noninteractive"]) { line in
            log.output(line)
        }
        invalidate()
        log.ok(t("%@ installed", what.spokenName))
    }

    /// Stamped with what the server said, so a build can later ask whether the mirror has
    /// moved on without fetching a gigabyte to find out.
    private func installDataPack(_ pack: DataPack, log: Log,
                                 progress: InstallProgress? = nil,
                                 name: String) async throws {
        log.step("downloading \(name)")
        Paths.ensure(Paths.tools)
        let downloader = Downloader(log: log)
        progress?.downloading(t("downloading %@", name), downloader.progress)
        // The count a build uses: parts are laid out per count, so a differing one would
        // start the download again instead of resuming it.
        try await pack.fetch(using: downloader,
                             connections: settings.settings.downloadConnections)
        log.ok("\(pack.file.lastPathComponent) ready — \(Fmt.bytes(FileTools.size(of: pack.file)))")
    }

    /// Downloads a mkgmap.org.uk zip, finds the jar inside it, and installs it plus its lib/.
    private func installJarBundle(pageURL: String,
                                  pattern: String,
                                  fallbackFile: String,
                                  jarName: String,
                                  destination: URL,
                                  log: Log,
                                  progress: InstallProgress? = nil) async throws {
        let base = "https://www.mkgmap.org.uk/download/"
        var file = fallbackFile

        progress?.step(t("looking up the latest %@ release", jarName))
        log.step("looking up the latest \(jarName) release")
        if let url = URL(string: pageURL),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let html = String(data: data, encoding: .utf8) {
            let matches = html.allMatches(pattern)
            // Releases are revision-numbered; take the highest.
            let best = matches.compactMap { match -> (Int, String)? in
                guard let digits = match.allMatches("[0-9]+").first, let n = Int(digits) else { return nil }
                return (n, match)
            }.max(by: { $0.0 < $1.0 })
            if let best { file = best.1 }
        }
        log.append("using \(file)")

        guard let downloadURL = URL(string: base + file) else {
            throw InstallError.failed("bad download URL for \(file)")
        }

        Paths.ensure(Paths.tools)
        let zipURL = Paths.tools.appendingPathComponent(file)
        let downloader = Downloader(log: log)
        progress?.downloading(t("downloading %@", file), downloader.progress)
        try await downloader.download(url: downloadURL, to: zipURL, connections: 4)
        log.ok("downloaded \(Fmt.bytes(FileTools.size(of: zipURL)))")

        // Unpack into a staging dir, then lift the jar (and any lib/) into place.
        let staging = Paths.tools.appendingPathComponent("unpack-\(UUID().uuidString.prefix(8))")
        Paths.ensure(staging)
        defer { FileTools.removeIfPresent(staging); FileTools.removeIfPresent(zipURL) }

        guard let archive = Archive.current else {
            throw InstallError.unsupported(Archive.missingNote())
        }
        progress?.step(t("unpacking"))
        let unpack = archive.unpack(zipURL, into: staging)
        try await ProcessRunner().run(unpack.executable, unpack.arguments) { line in
            log.output(line)
        }

        guard let jar = findFile(named: jarName, under: staging) else {
            throw InstallError.failed("\(jarName) was not inside \(file)")
        }

        FileTools.removeIfPresent(destination)
        Paths.ensure(destination)
        try FileManager.default.copyItem(at: jar, to: destination.appendingPathComponent(jarName))

        // mkgmap ships a lib/ of dependencies next to the jar.
        let lib = jar.deletingLastPathComponent().appendingPathComponent("lib")
        if FileTools.exists(lib) {
            try? FileManager.default.copyItem(at: lib, to: destination.appendingPathComponent("lib"))
        }
        log.ok("installed \(jarName) → \(Paths.display(destination))")
    }

    private func findFile(named: String, under root: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in walker where url.lastPathComponent == named {
            return url
        }
        return nil
    }

    /// Installs the latest mkgmap release, or `fallbackFile` where the release page cannot
    /// be read.
    func installMkgmap(log: Log, runner: ProcessRunner,
                       progress: InstallProgress? = nil) async throws {
        try await installJarBundle(
            pageURL: "https://www.mkgmap.org.uk/download/mkgmap.html",
            pattern: "mkgmap-r([0-9]+)\\.zip",
            fallbackFile: "mkgmap-r4924.zip",
            jarName: "mkgmap.jar",
            destination: Paths.tools.appendingPathComponent("mkgmap", isDirectory: true),
            log: log, progress: progress)
    }

    private func installPyhgtmap(log: Log, runner: ProcessRunner,
                                 progress: InstallProgress? = nil) async throws {
        // pyhgtmap lives in a virtualenv, which needs a python3 to build it from.
        if findPython3() == nil, Toolchain.canInstall(.python) {
            try await installSystemPackage(.python, log: log, runner: runner,
                                           progress: progress)
        }
        guard let python = findPython3() else {
            throw InstallError.unsupported("python3 not found — install with: "
                                           + Platform.installHint(.python))
        }
        Paths.ensure(Paths.tools)

        if !FileTools.exists(ToolLocations.inVirtualEnvironment("pip", of: Paths.venv)) {
            progress?.step(t("creating a private Python environment"))
            log.step("creating a private Python environment")
            try await runner.run(python, ["-m", "venv", Paths.venv.path]) { log.append($0) }
        }

        progress?.step(t("installing pyhgtmap"))
        log.step("installing pyhgtmap (this pulls in a few geo libraries — give it a minute)")
        let pip = ToolLocations.inVirtualEnvironment("pip", of: Paths.venv).nativePath
        try await runner.run(pip, ["install", "--upgrade", "--disable-pip-version-check",
                                   "pyhgtmap"]) { line in
            // pip is chatty; keep the useful lines.
            if line.hasPrefix("Collecting") || line.hasPrefix("Successfully")
                || line.hasPrefix("Installing") || line.contains("error") {
                log.output(line)
            }
        }

        // The file itself, not `findPyhgtmap()`, whose answer was cached before this
        // install ran.
        guard FileTools.isExecutable(pyhgtmapBinary.nativePath) else {
            throw InstallError.failed("pyhgtmap did not appear in \(Paths.display(Paths.venv))")
        }

        log.ok("pyhgtmap ready")
    }
}
