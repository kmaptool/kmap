import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a module of its own outside Apple's platforms.
import FoundationNetworking
#endif

/// The pinned downloads kmap unpacks itself: mkgmap's jar bundles and the data packs.
extension Toolchain {
    /// Stamped with what the server said, so a build can later ask whether the mirror has
    /// moved on without fetching a gigabyte to find out.
    func installDataPack(
        _ pack: DataPack,
        log: Log,
        progress: InstallProgress? = nil,
        name: String
    ) async throws {
        log.step("downloading \(name)")
        Paths.ensure(Paths.tools)
        let downloader = Downloader(log: log)
        progress?.downloading(t("downloading %@", name), downloader.progress)
        // The count a build uses: parts are laid out per count, so a differing one would
        // start the download again instead of resuming it.
        try await pack.fetch(
            using: downloader,
            connections: settings.settings.downloadConnections
        )
        log.ok("\(pack.file.lastPathComponent) ready — \(Fmt.bytes(FileTools.size(of: pack.file)))")
    }

    /// Downloads a pinned mkgmap.org.uk zip, checks it, finds the jar inside it, and
    /// installs it plus its lib/.
    private func installJarBundle(
        _ pinned: Toolchain.PinnedDownload,
        jarName: String,
        destination: URL,
        keeping: [String] = [],
        checkingUse: Bool = true,
        log: Log,
        progress: InstallProgress? = nil
    ) async throws {
        let file = pinned.file
        log.append("using \(file)")
        guard let downloadURL = pinned.url else {
            throw InstallError.failed("bad download URL for \(file)")
        }

        Paths.ensure(Paths.tools)
        let zipURL = Paths.tools.appendingPathComponent(file)
        let downloader = Downloader(log: log)
        progress?.downloading(t("downloading %@", file), downloader.progress)
        try await downloader.download(url: downloadURL, to: zipURL, connections: 4)
        do {
            try Toolchain.verify(zipURL, against: pinned)
        } catch {
            FileTools.removeIfPresent(zipURL)
            throw error
        }
        log.ok("downloaded \(Fmt.bytes(FileTools.size(of: zipURL))), checksum verified")

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

        // Put together beside the destination and swapped in whole: without its lib/ the
        // jar still answers --version, and would pass for installed.
        let fresh = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".new", isDirectory: true)
        FileTools.removeIfPresent(fresh)
        Paths.ensure(fresh)
        do {
            try FileTools.copy(jar, to: fresh.appendingPathComponent(jarName))
            // mkgmap ships a lib/ of dependencies next to the jar.
            let lib = jar.deletingLastPathComponent().appendingPathComponent("lib")
            if FileTools.exists(lib) {
                try FileTools.copy(lib, to: fresh.appendingPathComponent("lib"))
            }
            // The patched jar built beside the stock one goes on with it: a jar no longer
            // there is not built again unasked, and one out of date renews itself.
            for kept in keeping where FileTools.exists(destination.appendingPathComponent(kept)) {
                try FileTools.copy(destination.appendingPathComponent(kept), to: fresh.appendingPathComponent(kept))
            }
            if checkingUse {
                try Toolchain.replaceUnused(destination, with: fresh)
            } else {
                try Toolchain.swapping { try FileTools.replace(destination, with: fresh) }
            }
        } catch {
            FileTools.removeIfPresent(fresh)
            throw error
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

    /// Installs the mkgmap release kmap knows, `Toolchain.mkgmapRelease`.
    /// - Parameter checkingUse: off for the patch a build renews before its first mkgmap
    ///   run: the build's own hold on the tools would refuse it.
    func installMkgmap(
        log: Log,
        runner: ProcessRunner,
        progress: InstallProgress? = nil,
        checkingUse: Bool = true
    ) async throws {
        try await installJarBundle(
            Toolchain.mkgmapRelease,
            jarName: "mkgmap.jar",
            destination: Paths.tools.appendingPathComponent("mkgmap", isDirectory: true),
            keeping: [Toolchain.patchedMkgmapName],
            checkingUse: checkingUse,
            log: log,
            progress: progress
        )
        JavaWarmStart.forgetAll(for: Paths.tools.appendingPathComponent("mkgmap/mkgmap.jar"))
    }
}
