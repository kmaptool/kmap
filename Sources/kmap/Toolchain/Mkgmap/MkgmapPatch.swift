import Foundation

/// Builds a patched copy of mkgmap.jar from the matching source release.
///
/// The patched jar sits beside the original under a name of its own and carries a marker
/// naming the patch version; it is rebuilt whenever that version changes.
///
/// The Java of the patch, which is GPL as mkgmap is, lives in `MkgmapPatchEdits.swift`; see
/// NOTICE.md.
extension Toolchain {
    /// Compiles for the Java that runs mkgmap where it is older than the JDK compiling:
    /// classes for a newer Java do not load in it. Nothing where they agree, as a JDK 8
    /// has no `--release`.
    static func releaseOptions(kit: Int?, runtime: Int?) -> [String] {
        guard let kit, let runtime, runtime < kit else { return [] }
        return ["--release", String(max(runtime, 8))]
    }

    /// The patch was asked for once and an older kmap built it: its edits have changed.
    static func isStalePatch(_ jar: URL) -> Bool {
        let found = patchVersion(of: jar)
        return found > 0 && found < patchVersion
    }

    var patchIsStale: Bool { Toolchain.isStalePatch(Toolchain.patchedMkgmapURL) }

    /// The rebuild in flight, and whether one has failed in this process.
    private static let renewal = Locked<(running: Task<Bool, Never>?, failed: Bool)>((nil, false))

    /// Rebuilds the patch an older kmap left, so asking for the patch once is enough.
    /// Nothing is installed where no patched jar is. One rebuild runs at a time and every
    /// caller waits for it; a failed one leaves the old jar, which builds as the stock
    /// mkgmap does, and is not tried again by this process.
    /// - Returns: whether the patch is the current one now.
    @discardableResult
    func renewStalePatch(log: Log, runner: ProcessRunner = ProcessRunner()) async -> Bool {
        let task: Task<Bool, Never>? = Toolchain.renewal.withLock { state in
            if let running = state.running { return running }
            guard !state.failed else { return nil }
            let made = Task.detached { [self] in
                defer { Toolchain.renewal.withLock { $0.running = nil } }
                guard patchIsStale else { return mkgmapIsPatched }
                do {
                    try await install("mkgmap-patch", log: log, runner: runner)
                    return true
                } catch {
                    if !Task.isCancelled { Toolchain.renewal.withLock { $0.failed = true } }
                    log.warn(
                        "the mkgmap patch was not rebuilt: "
                            + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    )
                    return false
                }
            }
            state.running = made
            return made
        }
        guard let task else { return false }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func patchMkgmap(
        log: Log,
        runner: ProcessRunner,
        progress: InstallProgress? = nil
    ) async throws {
        let stock = try await stockMkgmap(log: log, runner: runner, progress: progress)
        progress?.step(t("building the patched mkgmap"))
        // The patch is compiled here, so it takes a JDK — not whichever Java runs mkgmap.
        guard let java = findJavaKit(), java.isKit else {
            throw InstallError.unsupported(
                findJava() == nil
                    ? t("Java is needed to build the patch")
                    : t("this Java is a runtime — install a full JDK, or build without the patch")
            )
        }
        let javac = ToolLocations.companion("javac", of: java.path)
        let jarTool = ToolLocations.companion("jar", of: java.path)

        // The source archive has to match the jar, or the compiled classes will not fit it.
        guard let archive = Archive.current else {
            throw InstallError.unsupported(Archive.missingNote())
        }
        let revision = try mkgmapRevision(of: stock, archive: archive)
        log.step("patching mkgmap r\(revision)")

        let staging = Paths.tools.appendingPathComponent("mkgmap-patch-\(UUID().uuidString.prefix(8))")
        Paths.ensure(staging)
        defer { FileTools.removeIfPresent(staging) }

        let src = try await fetchMkgmapSource(
            revision: revision,
            into: staging,
            archive: archive,
            log: log,
            runner: runner
        )
        try applyPatchEdits(under: src, revision: revision, log: log)

        let classes = staging.appendingPathComponent("classes")
        Paths.ensure(classes)
        var classpath = [stock.nativePath]
        let libs = stock.deletingLastPathComponent().appendingPathComponent("lib")
        if let jars = try? FileManager.default.contentsOfDirectory(at: libs, includingPropertiesForKeys: nil) {
            classpath += jars.filter { $0.pathExtension == "jar" }.map(\.nativePath)
        }
        // `javac` and `jar` are JVMs too and take JVM options only through `-J`, so the
        // options this machine's Java needs to start are passed to them as well.
        var arguments =
            java.toolOptions
            + Toolchain.releaseOptions(kit: java.major, runtime: findJava()?.major)
            + [
                "-nowarn", "-classpath",
                classpath.joined(separator: ToolLocations.classpathSeparator()),
                "-d", classes.nativePath
            ]
        // Compile exactly the files the edits touched: a hand-kept list would ship stock
        // bytecode for any newly patched file.
        arguments += Set(Toolchain.mkgmapSourceEdits.map(\.0)).sorted()
            .map { src.appendingPathComponent($0).nativePath }
        log.step("compiling")
        try await runner.run(javac, arguments) { line in log.output(line) }

        // Built aside and moved in whole: a build that fails or is stopped leaves the jar
        // that was there, with its marker, so an older patch is still seen as one.
        let home = Toolchain.patchedMkgmapURL.deletingLastPathComponent()
        Paths.ensure(home)
        let built = staging.appendingPathComponent(Toolchain.patchedMkgmapName)
        try FileTools.copy(stock, to: built)

        // The mkgmap manifest names its dependencies with a relative Class-Path, so the jar
        // runs only with lib/ beside it, and the patched copy lands in another directory.
        let stockLibs = stock.deletingLastPathComponent().appendingPathComponent("lib")
        let ourLibs = home.appendingPathComponent("lib")
        if FileTools.exists(stockLibs), stockLibs != ourLibs {
            FileTools.removeIfPresent(ourLibs)
            try FileTools.copy(stockLibs, to: ourLibs)
            log.append("copied lib/ beside the patched jar")
        }

        let marker = classes.appendingPathComponent(Toolchain.patchMarker)
        let stamp =
            "built-from: r\(revision)\npatch-version: \(Toolchain.patchVersion)\n"
            + "option: --x-shape-clip-overlap\n"
            + "option: --x-line-draw-order\n"
            + "option: --x-shape-lift\n"
        try FileTools.write(stamp, to: marker)
        try await runner.run(
            jarTool,
            java.toolOptions
                + [
                    "uf", built.nativePath,
                    "-C", classes.nativePath, "uk",
                    "-C", classes.nativePath, Toolchain.patchMarker
                ]
        ) { line in log.output(line) }

        guard Toolchain.isPatched(built) else {
            throw InstallError.failed("the patched jar came out without its marker")
        }
        FileTools.removeIfPresent(Toolchain.patchedMkgmapURL)
        try FileTools.move(built, to: Toolchain.patchedMkgmapURL)
        // The JVM's cache was recorded for the jar that was here.
        JavaWarmStart.forgetAll(beside: Toolchain.patchedMkgmapURL)
        log.ok("patched mkgmap at \(Paths.display(Toolchain.patchedMkgmapURL))")
    }

    /// An unpatched jar to build from; a stock release is fetched when none is installed.
    private func stockMkgmap(
        log: Log,
        runner: ProcessRunner,
        progress: InstallProgress?
    ) async throws -> URL {
        if mkgmapCandidates().first(where: { FileTools.exists($0) && Toolchain.patchVersion(of: $0) == 0 }) == nil {
            log.step("fetching a stock mkgmap to patch")
            try await installMkgmap(log: log, runner: runner, progress: progress)
            invalidate()
        }
        guard
            // Never the patched jar itself: an install killed between the copy and the
            // marker leaves one without a version, and it is about to be replaced.
            let stock = mkgmapCandidates().first(where: {
                $0 != Toolchain.patchedMkgmapURL && FileTools.exists($0) && Toolchain.patchVersion(of: $0) == 0
            })
        else {
            throw InstallError.unsupported("no unpatched mkgmap.jar to build from")
        }
        return stock
    }

    /// The revision the jar was built from, read from its own version file.
    private func mkgmapRevision(of stock: URL, archive: Archive) throws -> String {
        let version = archive.read("mkgmap-version.properties", from: stock)
        guard let listing = ProcessProbe.capture(version.executable, version.arguments),
            let revision = listing.allMatches("svn.version: ([0-9]+)").first?
                .allMatches("[0-9]+").first
        else {
            throw InstallError.failed("could not read the mkgmap revision from \(stock.lastPathComponent)")
        }
        return revision
    }

    /// Downloads and unpacks the source release matching the jar.
    ///
    /// - Returns: the unpacked `src` directory.
    private func fetchMkgmapSource(
        revision: String,
        into staging: URL,
        archive: Archive,
        log: Log,
        runner: ProcessRunner
    ) async throws -> URL {
        guard let pinned = Toolchain.mkgmapSources[revision], let url = pinned.url else {
            throw InstallError.unsupported(
                t(
                    "the patch is built for mkgmap r%@ only, and this mkgmap is r%@",
                    Toolchain.mkgmapSources.keys.sorted().joined(separator: ", r"),
                    revision
                )
            )
        }
        let file = pinned.file
        // Kept beside the jar once it has unpacked, so rebuilding the patch for a newer
        // kmap needs no network. Checked like a download: it is compiled all the same.
        let kept = Toolchain.patchedMkgmapURL.deletingLastPathComponent().appendingPathComponent(file)
        let zip = staging.appendingPathComponent(file)
        if FileTools.exists(kept), (try? Toolchain.verify(kept, against: pinned)) != nil {
            try FileTools.copy(kept, to: zip)
        } else {
            FileTools.removeIfPresent(kept)
            try await Downloader(log: log).download(url: url, to: zip, connections: 4)
            try Toolchain.verify(zip, against: pinned)
        }
        let unpack = archive.unpack(zip, into: staging)
        do {
            try await runner.run(unpack.executable, unpack.arguments) { _ in }
        } catch {
            FileTools.removeIfPresent(kept)
            throw error
        }
        if !FileTools.exists(kept) {
            Paths.ensure(kept.deletingLastPathComponent())
            try? FileTools.copy(zip, to: kept)
        }

        guard
            let root =
                (try? FileManager.default.contentsOfDirectory(
                    at: staging,
                    includingPropertiesForKeys: nil
                ))?
                .first(where: { $0.lastPathComponent.hasPrefix("mkgmap-r") && !$0.pathExtension.contains("zip") })
        else {
            throw InstallError.failed("the source archive did not unpack as expected")
        }
        return root.appendingPathComponent("src")
    }

    /// Applies every edit of `mkgmapSourceEdits`, exact-anchor only.
    private func applyPatchEdits(under src: URL, revision: String, log: Log) throws {
        let edits = Toolchain.mkgmapSourceEdits
        for (relative, anchor, replacement) in edits {
            let file = src.appendingPathComponent(relative)
            guard var text = try? String(contentsOf: file, encoding: .utf8) else {
                throw InstallError.failed("missing source file \(relative)")
            }
            guard let found = text.range(of: anchor) else {
                throw InstallError.failed(
                    "r\(revision) has changed \(relative) — the patch needs revisiting"
                )
            }
            text.replaceSubrange(found, with: replacement)
            try FileTools.write(text, to: file)
        }
        log.append("\(edits.count) edit(s) applied to \(Set(edits.map(\.0)).count) file(s)")
    }
}
