import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a module of its own outside Apple's platforms.
import FoundationNetworking
#endif

/// kmap's own JDK, for a machine whose package manager has none to give.
extension Toolchain {
    /// Downloads a JDK into kmap's own directory, for a machine with no package manager
    /// that can install one.
    ///
    /// The archive is checked against the checksum Adoptium publishes for it before
    /// anything is unpacked, and the unpacked tree replaces any earlier one only once a
    /// `java` inside it has been found and has run.
    func installOwnJava(
        log: Log,
        runner: ProcessRunner,
        progress: InstallProgress? = nil
    ) async throws {
        guard JavaDownload.isAvailable() else { throw JavaDownload.Trouble.unsupportedMachine }
        // 2 installs would share 1 archive and 1 home.
        Paths.ensure(Paths.locks)
        guard let held = HeldLock(trying: Paths.locks.appendingPathComponent("java-install.lock")) else {
            throw InstallError.failed(t("another kmap is installing Java — wait for it to end"))
        }
        defer { withExtendedLifetime(held) {} }
        // The newest release first, an older one where that cannot be had or does not run.
        var failure: Error = JavaDownload.Trouble.noRelease(JavaDownload.features[0])
        for (at, feature) in JavaDownload.features.enumerated() {
            do {
                try await installOwnJava(feature: feature, log: log, runner: runner, progress: progress)
                return
            } catch {
                // A stop arrives as whatever the download or the unpacking was doing: it
                // ends the install rather than trying an older Java.
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                guard Toolchain.stepsDown(after: error, feature: feature) else { throw error }
                failure = error
                if at + 1 < JavaDownload.features.count {
                    log.append(
                        "Java \(feature): \(error.localizedDescription) — Java \(JavaDownload.features[at + 1]) instead"
                    )
                }
            }
        }
        throw failure
    }

    /// Whether a failed install of Java `feature` goes on to an older one: only where this
    /// one cannot be had here or does not run. A network or disk that fails fails the older
    /// one too, and a checksum that does not match is not to be stepped round.
    static func stepsDown(after error: Error, feature: Int) -> Bool {
        guard let trouble = error as? JavaDownload.Trouble else { return false }
        return [.noRelease(feature), .unsupportedMachine, .noJavaInside].contains(trouble)
    }

    private func installOwnJava(
        feature: Int,
        log: Log,
        runner: ProcessRunner,
        progress: InstallProgress?
    ) async throws {
        progress?.step(t("looking up the current Java %d build", feature))
        log.step(t("looking up the current Java %d build", feature))
        guard let assets = JavaDownload.assetsURL(feature: feature) else {
            throw JavaDownload.Trouble.unsupportedMachine
        }
        // Named explicitly: the API refuses a request that sends no User-Agent, and
        // what URLSession writes there differs between platforms.
        var request = URLRequest(url: assets)
        request.setValue("kmap/\(Version.number)", forHTTPHeaderField: "User-Agent")
        let (listing, response) = try await URLSession.shared.data(for: request)
        // Not found is the API saying it has no such build here; any other refusal is the
        // server's trouble, which an older Java would meet too.
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw status == 404 ? JavaDownload.Trouble.noRelease(feature) : DownloadError.badStatus(status)
        }
        let release = try JavaDownload.release(fromAssets: listing, feature: feature)
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

        // It has to run here, not only be there: a build for an OS newer than this one
        // unpacks and then does not start. Asked as the probe asks, WSL1's options too.
        guard let unpacked = JavaDownload.javaBinary(under: staging),
            Toolchain.javaRescueOptions.contains(where: { options in
                ProcessProbe.capture(unpacked.path, options + ["-version"])?.lowercased().contains("version \"") == true
            })
        else {
            throw JavaDownload.Trouble.noJavaInside
        }
        Paths.ensure(JavaDownload.home.deletingLastPathComponent())
        try Toolchain.replaceUnused(JavaDownload.home, with: staging)

        invalidate()
        guard let own = JavaDownload.installed(), let java = Self.runtime(at: own.path, compilerNeeded: false) else {
            throw JavaDownload.Trouble.noJavaInside
        }
        log.ok(t("Java ready — %@", java.version))
        // kmap's own runs only where it is newer than the one found, and never in place
        // of one named in the settings or JAVA_HOME.
        if let used = findJava(), used.path != java.path {
            let named = ToolLocations.namedJava(configured: configuredJava).contains(used.path)
            log.append(
                t(
                    named ? "builds go on with %1$@, which you named" : "builds go on with %1$@, which is as new",
                    "\(used.path) (\(used.version))"
                )
            )
        }
    }
}
