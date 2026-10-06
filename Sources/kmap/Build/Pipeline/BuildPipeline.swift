import Foundation

/// Runs a recipe end to end: fetch the extract, build elevation data, split into tiles,
/// compile with mkgmap, and lay the finished .img files in the output folder.
///
/// All mutable state is guarded by `lock` and read through `snapshot()`, so the render
/// loop never blocks on the work.
final class BuildPipeline: Sendable {
    let log: Log
    let recipe: BuildRecipe
    let downloadProgress = DownloadProgress()

    let settings: SettingsStore
    let toolchain: Toolchain
    let styles: StyleCatalog

    /// The stages, kept where a progress monitor can hold them without holding the build.
    let board = StageBoard()

    /// One step at a time through `withLock`; a change that reads what it writes takes
    /// the lock once, not per field.
    let state = Locked(Run())

    // One field each, for the stages that read or set a single thing.
    var outlineElevationCells: [(lat: Int, lon: Int)]? {
        get { state.withLock { $0.outlineElevationCells } }
        set { state.withLock { $0.outlineElevationCells = newValue } }
    }
    var outputGroups: [String] {
        get { state.withLock { $0.outputGroups } }
        set { state.withLock { $0.outputGroups = newValue } }
    }
    var gmapBundle: URL? {
        get { state.withLock { $0.gmapBundle } }
        set { state.withLock { $0.gmapBundle = newValue } }
    }
    var burnedElevationDirectories: [URL] {
        get { state.withLock { $0.burnedElevationDirectories } }
        set { state.withLock { $0.burnedElevationDirectories = newValue } }
    }
    var repairMoves: [MapElementKind: [Int: Int]] {
        get { state.withLock { $0.repairMoves } }
        set { state.withLock { $0.repairMoves = newValue } }
    }
    var pendingPackUpdates: [(pack: DataPack, news: DataPack.News)] {
        get { state.withLock { $0.pendingPackUpdates } }
        set { state.withLock { $0.pendingPackUpdates = newValue } }
    }
    var wasCancelled: Bool { state.withLock { $0.wasCancelled } }

    /// - Parameter showing: the lowest severity the caller wants to be shown. The log
    ///   file beside the build keeps everything whatever this says.
    init(
        recipe: BuildRecipe,
        settings: SettingsStore,
        toolchain: Toolchain,
        styles: StyleCatalog,
        showing: LogSeverity = .info
    ) {
        self.recipe = recipe
        self.settings = settings
        self.toolchain = toolchain
        self.styles = styles
        Paths.ensure(Paths.logs)
        let logFile = Paths.logs.appendingPathComponent("\(recipe.areaSlug)-\(Int(Date().timeIntervalSince1970)).log")
        self.log = Log(mirrorTo: logFile, showing: showing)
    }

    // MARK: Lifecycle

    func start() {
        // Asked and answered in one step, so two callers cannot both start it.
        let alreadyStarted = state.withLock { run -> Bool in
            guard run.task == nil else { return true }
            run.startedAt = Date()
            run.task = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.run()
            }
            return false
        }
        _ = alreadyStarted
    }

    func cancel() {
        let active = state.withLock { run -> Run in
            run.wasCancelled = true
            return run
        }
        log.warn("cancelling…")
        for runner in active.runners { runner.cancel() }
        for downloader in active.downloaders { downloader.cancel() }
        active.elevation?.cancel()
        active.task?.cancel()
    }

    /// Whether cancel() has been called, or kmap is leaving and takes its tools along.
    var isCancelled: Bool { wasCancelled || ChildProcess.isLeaving }

    /// The same for work on threads of its own, which the task's cancellation misses; also
    /// true while the elevation is being stopped.
    var stopAsked: @Sendable () -> Bool {
        { [weak self] in self.map { $0.state.withLock { $0.wasCancelled || $0.settling } } ?? true }
    }

    /// Throws where the build has been cancelled. A stage can end early for its own
    /// reasons - a killed tool, a dropped download - and the next must not start.
    func stopIfCancelled() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    /// A tool killed by `cancel()`, rather than one that failed.
    private func isRunnerCancellation(_ error: Error) -> Bool {
        if case ProcessRunner.RunError.cancelled = error { return true }
        return false
    }

    /// Re-throws the cancellation itself. Stages go on without what they could not get -
    /// contours, summit heights, annotation - but not without the build.
    func rethrowIfCancelled(_ error: Error) throws {
        if error is CancellationError
            || isRunnerCancellation(error)
            || (error as? URLError)?.code == .cancelled
            || isCancelled || Task.isCancelled
        {
            throw CancellationError()
        }
    }

    func publish(_ written: [Output]) {
        state.withLock { $0.outputs = written }
    }

    func retain(_ downloader: Downloader) {
        state.withLock { $0.downloaders.append(downloader) }
    }

    /// The elevation task, for `cancel()`. One registered after the build was cancelled
    /// is cancelled on the spot: the two can race.
    func retain(elevation task: Task<[URL], Error>) {
        let cancelled = state.withLock { run -> Bool in
            run.elevation = task
            return run.wasCancelled
        }
        if cancelled { task.cancel() }
    }

    /// Stops the elevation task and waits until it has. Stopped to be run again, its
    /// stages go back to not started; stopped by a failure, they stay for `finish`.
    func settleElevation(puttingStagesBack: Bool = true) async {
        // Its threads see only `stopAsked`, not the task's cancellation.
        let task = state.withLock { run in
            run.settling = true
            return run.elevation
        }
        task?.cancel()
        _ = await task?.result
        state.withLock { $0.settling = false }
        guard puttingStagesBack else { return }
        for id in [StageID.elevation, .elevationBuild] where board.status(of: id) == .running {
            set(id, .pending, "")
        }
    }

    func makeRunner() -> ProcessRunner {
        let runner = ProcessRunner()
        state.withLock { $0.runners.append(runner) }
        return runner
    }

    func finish(error: Error?) {
        let wasCancelled = state.withLock { run -> Bool in
            run.finishedAt = Date()
            // Finished with its maps in place: a stop asked at the last step is not one.
            if error == nil { run.wasCancelled = false }
            if let error {
                if run.wasCancelled || error is CancellationError {
                    run.wasCancelled = true
                } else {
                    run.failure = ErrorWords.of(error)
                }
            }
            return run.wasCancelled
        }

        // Both cancellation and failure mark the stage that was running, or it keeps its
        // spinner and reads as still working.
        if error != nil { board.stop(wasCancelled ? t("cancelled") : t("failed")) }

        if let error, !(error is CancellationError), !wasCancelled {
            log.error(ErrorWords.of(error))
        } else if wasCancelled {
            log.warn("build cancelled")
        } else {
            log.ok("build finished")
            if Measured.reported { reportTimings() }
        }
        // A task still winding down, as the elevation can be, changes no stage after this.
        board.close()
        // Last: whoever watches for the end then finds every stage and line of it.
        state.withLock { $0.finished = true }
    }

    // MARK: The run

    /// Held for the whole build: 2 builds of 1 region share its work folder. Kept among
    /// kmap's locks, where locking works, not in a work folder on a network share.
    var buildLock: URL { Self.lock(Self.workLockPrefix, for: workDirectory) }

    /// Held for the whole build too: 2 builds with their own work folders still share the
    /// output folder.
    var outputLock: URL { Self.lock(Self.outputLockPrefix, for: recipe.destinationDirectory) }

    static let workLockPrefix = "work-"
    static let outputLockPrefix = "output-"

    /// The lock of a folder, by the folder itself: past links, and case where the volume
    /// ignores case.
    static func lock(_ prefix: String, for folder: URL) -> URL {
        var path = resolvedPath(folder)
        #if os(Linux)
        // A Windows drive under WSL ignores case, as Windows does.
        if Platform.current.isWSL, path.hasPrefix("/mnt/") { path = path.lowercased() }
        #else
        path = path.lowercased()
        #endif
        return Paths.locks.appendingPathComponent(
            "\(prefix)\(String(TypLibrary.fingerprint(Data(path.utf8)), radix: 16)).lock"
        )
    }

    /// A path past its links, read from the nearest folder that is there: a folder not made
    /// yet reads as it will once made. On Windows past `subst` and mapped drives too.
    static func resolvedPath(_ url: URL) -> String {
        let head = nearestPresent(url)
        let tail = Array(url.standardizedFileURL.pathComponents.dropFirst(head.pathComponents.count))
        #if os(Windows)
        if let final = Win32File.finalPath(of: head.nativePath) {
            // A drive's root comes with its separator: `D:\` and `D:\maps` alike.
            let trimmed = final.hasSuffix("\\") ? String(final.dropLast()) : final
            return ([trimmed] + tail).joined(separator: "\\")
        }
        #endif
        var resolved = FileTools.resolvingLinks(head)
        for part in tail { resolved.appendPathComponent(part) }
        return resolved.path
    }

    static func nearestPresent(_ url: URL) -> URL {
        var head = url.standardizedFileURL
        while !FileTools.exists(head), head.pathComponents.count > 1 { head = head.deletingLastPathComponent() }
        return head
    }

    /// Folder and download locks of past days, which nothing asks for again; one held
    /// stays, and kmap's own fixed locks are not these.
    static func removeOldLocks(in locks: URL = Paths.locks, now: Date = Date()) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: locks, includingPropertiesForKeys: nil)) ?? []
        for entry in entries
        where [workLockPrefix, outputLockPrefix, "download-"].contains(where: { entry.lastPathComponent.hasPrefix($0) })
        {
            guard let changed = FileTools.modified(of: entry), now.timeIntervalSince(changed) > 2 * 86_400 else {
                continue
            }
            // A take refreshes the time, so a lock this old is used by none. One it could
            // not open goes too, where rights kept it out: another user's leftover.
            // Asked without a second hold on it: `held = nil` must let it go.
            var held = HeldLock(trying: entry)
            guard held?.isHeld == true || held?.refused == true else { continue }
            #if os(Windows)
            // Let go first: Windows removes no file held open.
            held = nil
            FileTools.removeIfPresent(entry)
            #else
            // Gone while still held, so no one locks the old file in between.
            FileTools.removeIfPresent(entry)
            held = nil
            #endif
        }
    }

    /// Marks a work folder as kmap's, so one in a folder the user chose can be swept.
    static let workMarker = ".kmap-work"
    /// Marks work files kept on purpose, which no sweep takes.
    static let keptMarker = ".kmap-kept"
    /// What a sweep moves a folder to before it removes it, so the lock is held a moment.
    static let sweptPrefix = ".kmap-swept-"

    /// What kmap puts in a work folder, for one an earlier kmap left without its mark.
    private static let workEntries: Set<String> = [
        "build", "tiles", "style", "typ", "contours", "dem-cells", "hgt-peaks", "elevation-clip.poly", "dem-clip.poly",
        "copyright.txt",
        workMarker, keptMarker
    ]

    private static let browserLeftovers: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

    /// Whether this map's work folder is kmap's: marked, empty (cut short before its mark),
    /// or left by an earlier kmap with only what kmap puts there and something only kmap makes.
    static func isKmapsWork(_ folder: URL) -> Bool {
        guard FileTools.isDirectoryItself(folder) else { return false }
        if FileTools.exists(folder.appendingPathComponent(workMarker)) { return true }
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        let names = all.filter { !browserLeftovers.contains($0) && !$0.hasPrefix("._") }
        func annotated(_ name: String) -> Bool { name.hasPrefix("annotated") && name.hasSuffix(".osm.pbf") }
        guard names.allSatisfy({ workEntries.contains($0) || annotated($0) }) else { return false }
        let contours =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("contours").path)) ?? []
        let made =
            [
                "elevation-clip.poly", "tiles/areas.list", "tiles/template.args", "build/tiles/tiles.args"
            ].contains { FileTools.exists(folder.appendingPathComponent($0)) }
            || contours.contains(where: { isKmapsContour($0) || isKmapsContourPart($0) })
        return names.isEmpty || made || names.contains(where: annotated)
    }

    /// `contour0001.osm.pbf`, as kmap names a cell's contours; another tool's are not it.
    private static func isKmapsContour(_ name: String) -> Bool {
        guard name.hasPrefix("contour"), name.hasSuffix(".osm.pbf") else { return false }
        let number = name.dropFirst("contour".count).dropLast(".osm.pbf".count)
        return number.count >= 4 && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The same, cut short: `contour0003.osm.pbf.<hex>.partial`.
    private static func isKmapsContourPart(_ name: String) -> Bool {
        guard name.hasSuffix(".partial"), let pbf = name.range(of: ".osm.pbf.") else { return false }
        return isKmapsContour(String(name[..<pbf.upperBound].dropLast()))
    }

    /// Whether `root` is kmap's own work root, where every folder is kmap's.
    static func isOwnWorkRoot(_ root: URL) -> Bool {
        var paths = [resolvedPath(root), resolvedPath(Paths.work)]
        #if !os(Linux)
        paths = paths.map { $0.lowercased() }
        #endif
        return paths[0] == paths[1]
    }

    /// The earlier work folder of this map goes, failed or kept: every stage makes its files
    /// again. So do other maps' left over 3 days that no build holds, unless work files
    /// are kept. Outside kmap's own root a folder must be kmap's work to go: one of the
    /// user's may have the same name.
    func clearEarlierWork(now: Date = Date()) throws {
        let ownRoot = Self.isOwnWorkRoot(recipe.workRoot)
        var freed: Int64 = 0
        if FileTools.exists(workDirectory) {
            guard ownRoot || Self.isKmapsWork(workDirectory) else {
                throw BuildError.workFolderNotKmaps(Paths.display(workDirectory))
            }
            freed += directorySize(workDirectory)
            FileTools.removeIfPresent(workDirectory)
        }
        // The folder this map had before its name took a mark: kmap's, kept by no one, and
        // held by no build.
        let unmarked = recipe.workRoot.appendingPathComponent(recipe.areaSlug, isDirectory: true)
        if recipe.slug != recipe.areaSlug, FileTools.exists(unmarked), Self.isKmapsWork(unmarked),
            !FileTools.exists(unmarked.appendingPathComponent(Self.keptMarker))
        {
            Paths.ensure(Paths.locks)
            var held = HeldLock(trying: Self.lock(Self.workLockPrefix, for: unmarked))
            if held?.isHeld == true {
                let size = directorySize(unmarked)
                if (try? FileTools.remove(unmarked)) != nil { freed += size }
            }
            held = nil
        }
        if !settings.settings.keepWorkFiles {
            freed += sweepAbandonedWork(now: now)
        }
        Paths.ensure(workDirectory)
        do {
            try FileTools.write("", to: workDirectory.appendingPathComponent(Self.workMarker))
        } catch {
            throw BuildError.workFolderUnwritable(Paths.display(workDirectory))
        }
        state.withLock { $0.madeWorkFolder = true }
        if freed > 0 { log.append("cleared \(Fmt.bytes(freed)) of work files left by earlier builds") }
    }

    /// Other maps' work folders kmap marked, left over 3 days.
    private func sweepAbandonedWork(now: Date) -> Int64 {
        let root = recipe.workRoot
        var freed: Int64 = 0
        func abandoned(_ folder: URL) -> Bool {
            // Another map's folder by its mark alone: a guess could take a user's folder, or
            // one an earlier kmap kept on purpose with no mark to say so.
            guard !FileTools.exists(folder.appendingPathComponent(Self.keptMarker)),
                let touched = FileTools.modified(of: folder.appendingPathComponent(Self.workMarker))
            else { return false }
            return now.timeIntervalSince(touched) > 3 * 86_400
        }
        for folder in FileTools.contents(of: root)
        where FileTools.isDirectoryItself(folder) && folder.lastPathComponent != workDirectory.lastPathComponent
            && abandoned(folder)
        {
            // Moved aside under the lock, asked again there, and removed after it: a build
            // of that map starting in that moment is told another runs.
            let aside = root.appendingPathComponent(Self.sweptPrefix + UUID().uuidString.prefix(8))
            var held = HeldLock(trying: Self.lock(Self.workLockPrefix, for: folder))
            // Where locks do not work at all, or the disk is too full for one, the folder's
            // own age decides.
            let moved = held != nil && abandoned(folder) && (try? FileTools.move(folder, to: aside)) != nil
            held = nil
            guard moved else { continue }
            freed += directorySize(aside)
            FileTools.removeIfPresent(aside)
        }
        // What a sweep stopped midway left.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix(Self.sweptPrefix) {
            let aside = root.appendingPathComponent(name)
            freed += directorySize(aside)
            FileTools.removeIfPresent(aside)
        }
        return freed
    }

    func run() async {
        var locks: [HeldLock] = []
        do {
            // See `buildLock` and `outputLock`.
            Paths.ensure(Paths.locks)
            Self.removeOldLocks()
            // Held by `locks` alone, so `locks = []` lets them go before the end is told.
            if let build = HeldLock(trying: buildLock) {
                locks.append(build)
            } else {
                throw BuildError.alreadyBuilding(recipe.mapName)
            }
            if let output = HeldLock(trying: outputLock) {
                locks.append(output)
            } else {
                throw BuildError.outputInUse(Paths.display(recipe.destinationDirectory))
            }
            // Waited for only while an install swaps a tool in, a moment.
            if let tools = await HeldLock.waiting(for: Toolchain.inUseLock, shared: true) {
                locks.append(tools)
            } else {
                throw CancellationError()
            }
            try await preflight()
            try stopIfCancelled()
            try await updateDataPacks()
            try stopIfCancelled()
            // Before anything looks at the cache: a copy a killed run put aside is back.
            for region in recipe.regions { Self.settleSuspect(besides: Paths.cachedExtract(forRegion: region.id)) }
            let extracts = try await downloadExtracts()
            try stopIfCancelled()
            do {
                try await buildMap(from: extracts)
            } catch  where Self.readsLikeADamagedExtract(error) {
                // An extract would not decode. If one was damaged on disk it is fetched
                // again and the build carries on; this is tried once. The elevation already
                // started ends first, or it would write the same stages as the new one.
                await settleElevation()
                guard let fetched = try await refetchDamagedExtracts(among: extracts) else {
                    throw error
                }
                try stopIfCancelled()
                try await buildMap(from: fetched)
            }
            try stopIfCancelled()
            try await collect()
            unpinExtracts()
            locks = []
            finish(error: nil)
        } catch {
            // The elevation may still be writing into the work folder: the lock is let go
            // only once it has stopped, or the next build of this region meets its files.
            await settleElevation(puttingStagesBack: false)
            // Only where this build made the folder: otherwise it is an earlier build's.
            if !locks.isEmpty, state.withLock({ $0.madeWorkFolder }) {
                unpinExtracts()
                if settings.settings.keepWorkFiles {
                    try? FileTools.write("", to: workDirectory.appendingPathComponent(Self.keptMarker))
                } else {
                    log.append(
                        "the work files stay in \(Paths.display(workDirectory)) (\(Fmt.bytes(directorySize(workDirectory))))"
                            + " until a later build clears them"
                    )
                }
            }
            locks = []
            finish(error: error)
        }
    }

    /// Everything between the download and the collection: elevation, split and compile.
    private func buildMap(from cached: [URL]) async throws {
        let extracts = pinning(cached)
        // Elevation runs beside the split; only the first region's write waits on it,
        // where the contours are folded in, and the road repair waits on its tiles. A
        // retried split awaits the same task.
        let terrain = Gate<[URL]>()
        let elevationTask = Task { [self] in
            // Opened however the stage ends, so a waiting repair never hangs; a second open is
            // ignored.
            defer { terrain.open(demSearchPaths()) }
            return try await buildElevation(extracts: extracts, terrain: terrain)
        }
        retain(elevation: elevationTask)
        defer { elevationTask.cancel() }
        // Node count only approximates how much a tile draws, so the cap starts at the
        // setting and comes down only after a tile overflows the 16 MB drawing section.
        var cap = recipe.maxNodesPerTile
        // On overflow only the tiles mkgmap names are cut; halving the cap is the
        // fallback for an overflow reported without them.
        var areas: [TileSplitter.Area]? = nil
        var annotated: [String]? = nil
        var rounds = 0
        while true {
            let tiles = try await splitIntoTiles(
                extracts: extracts,
                contours: elevationTask,
                terrain: terrain,
                maxNodes: cap,
                areas: areas,
                annotated: &annotated
            )
            try stopIfCancelled()
            do {
                try await compile(tiles: tiles)
                break
            } catch BuildError.tileTooDense(let atCap, let failed) {
                // Not at work while the tiles are cut again: it starts anew after.
                set(.compile, .pending, "")
                rounds += 1
                guard rounds <= 8 else { throw BuildError.tileTooDense(atCap, failed: failed) }
                let indexes = Set(failed.map { $0 - recipe.mapIDBase })
                    .filter { $0 >= 0 && $0 < tiles.tiles.count }
                if !indexes.isEmpty {
                    let current = tiles.tiles.map { TileSplitter.Area(bbox: $0.bbox) }
                    let next = TileSplitter.refined(current, splitting: indexes)
                    guard next.count > current.count else {
                        throw BuildError.tileTooDense(atCap, failed: failed)
                    }
                    log.warn(
                        "\(indexes.count) tile(s) held more detail than Garmin's"
                            + " 16 MB drawing section takes — cutting just those in half"
                    )
                    areas = next
                    continue
                }
                let next = cap / 2
                guard next >= 200_000 else { throw BuildError.tileTooDense(cap, failed: []) }
                log.warn(
                    "a tile held more detail than Garmin's 16 MB drawing section takes"
                        + " — re-splitting at \(next / 1000)k nodes per tile"
                )
                cap = next
                areas = nil
            }
        }
    }

    // MARK: 1 - preflight

    /// A family id given by hand is this map's from now on, so the allocator gives it to no
    /// other map; one another map holds is said, the 2 then hiding each other on a device.
    private func keepFamilyID() {
        let key = BuildRecipe.identityKey(recipe.regions)
        let id = recipe.familyID
        // A reserved id given by hand serves this run only: kept, the next build would
        // move it again and ask for the copy just made to be removed. A note of an earlier
        // move waits for a build on the map's own id.
        if BuildRecipe.reservedFamilyIDs.contains(id) {
            log.warn("family id \(id) is mkgmap's own default: a map another tool built with it hides this one")
            return
        }
        // A reserved id stored for this map, given a new one by the form that only showed
        // it, is said here too.
        let stored = settings.settings.familyIDs[key]
        let replaced = stored.flatMap { BuildRecipe.reservedFamilyIDs.contains($0) && $0 != id ? $0 : nil }
        if let old = settings.movedFamilyID(for: key) ?? replaced {
            log.warn(
                "family id \(old) is mkgmap's own default, shared with maps other tools build:"
                    + " this map is \(id) from now on — remove its old copy from the device"
            )
            settings.update { $0.movedFamilyIDs[key] = nil }
        }
        guard settings.settings.familyIDs[key] != id else { return }
        // Asked of the file as it is now, under its lock: another kmap may have given the
        // id out since this one read it.
        var other: String?
        settings.update { settings in
            other = settings.familyIDs.first { $0.key != key && $0.value == id }?.key
            settings.familyIDs[key] = id
        }
        if let other { log.warn("family id \(id) is also the map of \(other)'s: a device shows only 1 of the 2") }
    }

    func preflight() async throws {
        set(.preflight, .running, t("checking tools"))
        log.step("preparing")
        // Before the download: mkgmap would stop on it only at the compile.
        guard CodePage.mkgmapTakes.contains(recipe.codePage) else { throw BuildError.unknownCodePage(recipe.codePage) }
        guard BuildRecipe.familyIDRange.contains(recipe.familyID) else {
            throw BuildError.familyIDOutOfRange(recipe.familyID)
        }
        keepFamilyID()

        guard toolchain.findJava() != nil else {
            throw BuildError.missingTool("Java — install it with: " + Platform.installHint(.java))
        }
        guard toolchain.findMkgmap() != nil else {
            throw BuildError.missingTool("mkgmap — install it from the Toolchain screen")
        }
        if toolchain.patchIsStale {
            detail(.preflight, t("rebuilding the mkgmap patch"))
            let older = Toolchain.patchState(of: Toolchain.patchedMkgmapURL).version < Toolchain.patchVersion
            log.step(
                older
                    ? "the mkgmap patch is from an older kmap, rebuilding it"
                    : "the mkgmap patch is built for a newer Java than this one, rebuilding it"
            )
            if await toolchain.renewStalePatch(log: log) {
                log.ok("the mkgmap patch is rebuilt")
            } else {
                log.warn("building without the patch, as with the stock mkgmap")
            }
        }
        // Copernicus and Viewfinder are read and converted in-process; pyhgtmap is needed
        // only by the sources that require an account.
        if recipe.needsElevationData, !credentialedSources.isEmpty,
            toolchain.findPyhgtmap() == nil
        {
            throw BuildError.missingTool(
                "pyhgtmap — needed for \(credentialedSources.joined(separator: ", "))."
                    + " Install it from the Toolchain screen, or pick copernicus, fabdem, gedtm or view1/view3"
            )
        }

        Paths.bootstrap()
        try clearEarlierWork()
        // The destination folder is created at the end, so a failed build leaves no
        // empty dated folder behind.

        // The work folder takes the most, the cache the downloads, the output the map.
        // Asked once per volume: on macOS each answer is a round trip to a system service.
        var asked: Set<String> = []
        for folder in [workDirectory, Paths.root, Self.nearestPresent(recipe.destinationDirectory)] {
            if let volume = FileTools.volume(of: folder), !asked.insert(volume).inserted { continue }
            let free = FileTools.freeSpaceBytes(at: folder)
            guard free > 0, free < 8_000_000_000 else { continue }
            log.warn(
                "only \(Fmt.bytes(free)) free on the volume holding \(Paths.display(folder)) — large regions may not fit"
            )
        }

        log.append("region:  \(recipe.mapName)  [\(recipe.regions.map(\.id).joined(separator: ", "))]")
        log.append("bbox:    \(recipe.coverage.display)")
        log.append(
            "style:   \(recipe.style.name) · code page \(recipe.codePage)"
                + (recipe.effectiveNameTagList.isEmpty ? "" : " · labels \(recipe.effectiveNameTagList)")
        )
        if recipe.codePage == CodePage.westernEuropean, recipe.coverage.isValid,
            recipe.coverage.minLon > CodePage.cyrillicMeridian
        {
            log.warn(
                "code page 1252 cannot hold Cyrillic — names would be transliterated to Latin."
                    + " Set 1251 if this region's names are in Cyrillic."
            )
        }
        log.append("product: family \(recipe.familyID) · tiles from \(recipe.mapIDBase)")
        log.append(
            "options: contours=\(recipe.contours ? "\(recipe.contourInterval) m" : "off")"
                + "  dem=\(recipe.demLayer ? "on" : "off")"
                + "  routable=\(recipe.routable)  index=\(recipe.searchIndex)"
        )
        log.append("levels:  \(recipe.levels.name) — \(recipe.levels.levels)")
        log.append("work:    \(Paths.display(workDirectory))")
        log.append("output:  \(recipe.splitMode.label) → \(Paths.display(recipe.destinationDirectory))")
        // Unfinished downloads leave parts behind; nothing else removes them. The tools
        // folder too: a half-fetched data pack is the largest of them.
        let freed =
            PartFiles.sweepAbandoned(in: Paths.cache)
            + PartFiles.sweepAbandoned(in: Paths.tools)
        if freed > 0 {
            log.append("cleared \(Fmt.bytes(freed)) left by downloads that were never finished")
        }
        // The packs this build reads sit in the toolchain for months; one HEAD request
        // each says whether the mirror has moved on. Fetching is the next stage's work.
        await checkDataPacks()
        set(.preflight, .done, t("ready"))
    }

    var workDirectory: URL { recipe.workDirectory }
}
