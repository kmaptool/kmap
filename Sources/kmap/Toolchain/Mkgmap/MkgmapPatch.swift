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
        guard let kit, kit >= 9, let runtime, runtime < kit else { return [] }
        return ["--release", String(max(runtime, 8))]
    }

    /// The Java release the patch's classes are compiled for, as the marker records it.
    static func classRelease(kit: Int?, runtime: Int?) -> Int? {
        guard let kit else { return nil }
        return releaseOptions(kit: kit, runtime: runtime).isEmpty ? kit : max(runtime ?? kit, 8)
    }

    /// The patch an older kmap built, or one compiled for a newer Java than the one that
    /// runs mkgmap now, which would not load its classes.
    var patchIsStale: Bool {
        Toolchain.isStalePatch(Toolchain.patchedMkgmapURL, runtime: findJava()?.major)
    }

    /// The same for `jar`, run by a Java of `runtime`. A jar never patched is not stale.
    static func isStalePatch(_ jar: URL, runtime: Int?) -> Bool {
        let state = patchState(of: jar)
        guard state.version > 0 else { return false }
        if state.version < patchVersion { return true }
        return isTooNew(release: state.release, for: runtime)
    }

    /// Whether classes compiled for `release` are too new for a Java of `runtime`. Unknown
    /// either way is not; nor is a runtime older than any the patch can be compiled for,
    /// which no rebuild would help.
    static func isTooNew(release: Int?, for runtime: Int?) -> Bool {
        guard let release, let runtime, runtime >= 8 else { return false }
        return runtime < release
    }

    /// Held while mkgmap or its patch is installed or rebuilt, by every kmap: they share
    /// the download and the folder.
    static var mkgmapLock: URL { Paths.locks.appendingPathComponent("mkgmap-install.lock") }

    /// The rebuild in flight, and whether one has failed in this process.
    private static let renewal = Locked<(current: MkgmapPatchRenewal?, failed: Bool)>((nil, false))

    /// Rebuilds the patch an older kmap left, so asking for the patch once is enough.
    /// Nothing is installed where no patched jar is. One rebuild runs at a time and every
    /// caller waits for it; a failed one leaves the old jar, which builds as the stock
    /// mkgmap does, and is not tried again by this process. A caller stopped stops waiting
    /// at once; the rebuild stops only with the last.
    /// - Returns: whether the patch is the current one now.
    @discardableResult
    func renewStalePatch(log: Log) async -> Bool {
        let renewal: MkgmapPatchRenewal? = Toolchain.renewal.withLock { state in
            if let current = state.current, !current.task.isCancelled, current.join() {
                return current
            }
            guard !state.failed else { return nil }
            // A rebuild stopped is let end first: they share the folder.
            let stopped = state.current?.task
            let made = MkgmapPatchRenewal()
            made.task = Task.detached { [self] in
                defer { Toolchain.renewal.withLock { if $0.current === made { $0.current = nil } } }
                _ = await stopped?.value
                return await rebuildStalePatch(log: log)
            }
            state.current = made
            return made
        }
        guard let renewal else { return false }
        let answer = MkgmapPatchRenewalAnswer()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answer.wait(continuation)
                Task.detached {
                    let (renewed, failure) = await renewal.task.value
                    guard answer.give(renewed) else { return }
                    if let failure { log.warn("the mkgmap patch was not rebuilt: " + failure) }
                    _ = renewal.leave()
                }
            }
        } onCancel: {
            if answer.give(false), renewal.leave() { renewal.task.cancel() }
        }
    }

    /// The rebuild itself, with a runner of its own: a caller's runner stopped would stop
    /// it for every caller.
    /// - Returns: whether the patch is current, and why not where it failed.
    private func rebuildStalePatch(log: Log) async -> (renewed: Bool, failure: String?) {
        guard patchIsStale else { return (mkgmapIsPatched, nil) }
        Paths.ensure(Paths.locks)
        // Another kmap's rebuild or install of mkgmap first, for a Java of its own: asked
        // again once it is done, so the last rebuild is for the oldest Java that asked. Then
        // shared as a build holds it, so no install of Java swaps it meanwhile. Waited for in
        // that order, or the wait keeps an install it waits on from swapping its tool in.
        guard let held = await HeldLock.waiting(for: Toolchain.mkgmapLock),
            let tools = await HeldLock.waiting(for: Toolchain.inUseLock, shared: true)
        else { return (false, nil) }
        defer { withExtendedLifetime((tools, held)) {} }
        guard patchIsStale else {
            invalidate()
            return (mkgmapIsPatched, nil)
        }
        do {
            Self.removeAbandonedStaging()
            defer { invalidate() }
            try await patchMkgmap(log: log, runner: ProcessRunner(), checkingUse: false)
            return (true, nil)
        } catch {
            var stopped = Task.isCancelled || error is CancellationError
            if case ProcessRunner.RunError.cancelled = error { stopped = true }
            guard !stopped else { return (false, nil) }
            Toolchain.renewal.withLock { $0.failed = true }
            return (false, (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func patchMkgmap(
        log: Log,
        runner: ProcessRunner,
        progress: InstallProgress? = nil,
        checkingUse: Bool = true
    ) async throws {
        let stock = try await stockMkgmap(log: log, runner: runner, progress: progress, checkingUse: checkingUse)
        progress?.step(t("building the patched mkgmap"))
        // The patch is compiled here, so it takes a JDK — not whichever Java runs mkgmap.
        guard let java = findJavaKit(), java.isKit else {
            throw InstallError.unsupported(
                findJava() == nil
                    ? t("Java is needed to build the patch")
                    : t("this Java is a runtime — install a full JDK, or build without the patch")
            )
        }
        let javac = java.kitTool("javac")
        let jarTool = java.kitTool("jar")

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
        // Copied beside, and swapped in with the jar as 1 set: a mkgmap another kmap runs
        // reads from this lib/.
        var swaps: [(destination: URL, fresh: URL)] = []
        if FileTools.exists(stockLibs), stockLibs != ourLibs {
            let fresh = staging.appendingPathComponent("lib", isDirectory: true)
            FileTools.removeIfPresent(fresh)
            try FileTools.copy(stockLibs, to: fresh)
            swaps.append((ourLibs, fresh))
        }

        let marker = classes.appendingPathComponent(Toolchain.patchMarker)
        let stamp =
            "built-from: r\(revision)\npatch-version: \(Toolchain.patchVersion)\n"
            + (Toolchain.classRelease(kit: java.major, runtime: findJava()?.major).map { "class-release: \($0)\n" }
                ?? "")
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
        swaps.append((Toolchain.patchedMkgmapURL, built))
        // Asked for by hand, it waits for no build; renewed by one, it goes in before mkgmap
        // first runs.
        if checkingUse, FileTools.exists(Toolchain.patchedMkgmapURL) {
            try Toolchain.whileUnused { try Toolchain.swapping { try FileTools.replace(swaps) } }
        } else {
            try Toolchain.swapping { try FileTools.replace(swaps) }
        }
        if swaps.count > 1 { log.append("copied lib/ beside the patched jar") }
        // The JVM's cache was recorded for the jar that was here.
        JavaWarmStart.forgetAll(for: Toolchain.patchedMkgmapURL)
        log.ok("patched mkgmap at \(Paths.display(Toolchain.patchedMkgmapURL))")
    }

    /// An unpatched jar to build from; a stock release is fetched when none is installed.
    private func stockMkgmap(
        log: Log,
        runner: ProcessRunner,
        progress: InstallProgress?,
        checkingUse: Bool
    ) async throws -> URL {
        if mkgmapCandidates().first(where: { FileTools.exists($0) && Toolchain.patchVersion(of: $0) == 0 }) == nil {
            log.step("fetching a stock mkgmap to patch")
            try await installMkgmap(log: log, runner: runner, progress: progress, checkingUse: checkingUse)
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
