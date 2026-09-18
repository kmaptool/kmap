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

    /// Everything about the run that changes while it runs. The stages run on several
    /// tasks at once, the elevation beside the split, and the screen reads from its own
    /// thread, so all of it sits behind one lock.
    struct Run {
        /// The timed pieces of work inside each stage; see `PipelineProgress`.
        var marks: [Mark] = []
        /// The degree cells elevation actually works on, once the region outlines have
        /// had their say. Nil until the elevation stage computes it; see
        /// trimElevationCells().
        var outlineElevationCells: [(lat: Int, lon: Int)]?
        var finished = false
        var failure: String?
        var wasCancelled = false
        var outputs: [Output] = []
        /// The output groups in the order the packer laid them, set by the compile stage;
        /// collect names the files p1, p2... along it.
        var outputGroups: [String] = []
        var startedAt = Date()
        var finishedAt: Date?
        /// Private copies of elevation tiles carrying OSM summit heights, written by
        /// `burnPeakElevations` and searched ahead of the shared cache.
        var burnedElevationDirectories: [URL] = []
        /// Where kmap's own marks ended up when the chosen TYP already drew their
        /// numbers. The rules emitting them are moved to match, in this build's style
        /// snapshot.
        var repairMoves: [MapElementKind: [Int: Int]] = [:]
        /// Data packs found to have moved on; see `StageDataUpdate`.
        var pendingPackUpdates: [(pack: DataPack, news: DataPack.News)] = []

        var runners: [ProcessRunner] = []
        var downloaders: [Downloader] = []
        var task: Task<Void, Never>?
        /// Runs beside the split, unstructured, so `cancel()` has to reach it by hand:
        /// the main task may be waiting on it, and a cancelled task is not released from
        /// a wait.
        var elevation: Task<[URL], Error>?
    }

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
    init(recipe: BuildRecipe, settings: SettingsStore, toolchain: Toolchain,
         styles: StyleCatalog, showing: LogSeverity = .info) {
        self.recipe = recipe
        self.settings = settings
        self.toolchain = toolchain
        self.styles = styles
        Paths.ensure(Paths.logs)
        let logFile = Paths.logs.appendingPathComponent("\(recipe.slug)-\(Int(Date().timeIntervalSince1970)).log")
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

    /// Whether cancel() has been called.
    var isCancelled: Bool { wasCancelled }

    /// The same, as a question for work that runs on threads of its own, where the
    /// task's cancellation is not seen: the splitter asks it between blobs.
    var stopAsked: () -> Bool {
        { [weak self] in self?.isCancelled ?? true }
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
            || isCancelled || Task.isCancelled {
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

    func makeRunner() -> ProcessRunner {
        let runner = ProcessRunner()
        state.withLock { $0.runners.append(runner) }
        return runner
    }

    func finish(error: Error?) {
        let wasCancelled = state.withLock { run -> Bool in
            run.finished = true
            run.finishedAt = Date()
            if let error {
                if run.wasCancelled || error is CancellationError {
                    run.wasCancelled = true
                } else {
                    run.failure = error.localizedDescription
                }
            }
            return run.wasCancelled
        }

        // Both cancellation and failure mark the stage that was running, or it keeps its
        // spinner and reads as still working.
        if error != nil {
            let reason = wasCancelled ? t("cancelled") : t("failed")
            for id in board.running { set(id, .failed, reason) }
        }

        if let error, !(error is CancellationError), !wasCancelled {
            log.error(error.localizedDescription)
        } else if wasCancelled {
            log.warn("build cancelled")
        } else {
            log.ok("build finished")
            if Measured.reported { reportTimings() }
        }
    }

    // MARK: The run

    func run() async {
        do {
            try await preflight()
            try stopIfCancelled()
            try await updateDataPacks()
            try stopIfCancelled()
            let extracts = try await downloadExtracts()
            try stopIfCancelled()
            do {
                try await buildMap(from: extracts)
            } catch where Self.readsLikeADamagedExtract(error) {
                // An extract would not decode. If one was damaged on disk it is fetched
                // again and the build carries on; this is tried once.
                guard let fetched = try await refetchDamagedExtracts(among: extracts) else {
                    throw error
                }
                try stopIfCancelled()
                try await buildMap(from: fetched)
            }
            try stopIfCancelled()
            try await collect()
            finish(error: nil)
        } catch {
            finish(error: error)
        }
    }

    /// Everything between the download and the collection: elevation, split and compile.
    private func buildMap(from extracts: [URL]) async throws {
        // Elevation runs beside the split; only the first region's write waits on it,
        // where the contours are folded in. A retried split awaits the same task.
        let elevationTask = Task { [self] in
            try await buildElevation(extracts: extracts)
        }
        retain(elevation: elevationTask)
        defer { elevationTask.cancel() }
        // Node count only approximates how much a tile draws, so the cap starts at the
        // setting and comes down only after a tile overflows the 16 MB drawing section.
        var cap = recipe.maxNodesPerTile
        // On overflow only the tiles mkgmap names are cut; halving the cap is the
        // fallback for an overflow reported without them.
        var areas: [TileSplitter.Area]? = nil
        var rounds = 0
        while true {
            let tiles = try await splitIntoTiles(extracts: extracts,
                                                 contours: elevationTask,
                                                 maxNodes: cap, areas: areas)
            try stopIfCancelled()
            do {
                try await compile(tiles: tiles)
                break
            } catch BuildError.tileTooDense(let atCap, let failed) {
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
                    log.warn("\(indexes.count) tile(s) held more detail than Garmin's"
                             + " 16 MB drawing section takes — cutting just those in half")
                    areas = next
                    continue
                }
                let next = cap / 2
                guard next >= 200_000 else { throw BuildError.tileTooDense(cap, failed: []) }
                log.warn("a tile held more detail than Garmin's 16 MB drawing section takes"
                         + " — re-splitting at \(next / 1000)k nodes per tile")
                cap = next
                areas = nil
            }
        }
    }

    // MARK: 1 - preflight

    func preflight() async throws {
        set(.preflight, .running, t("checking tools"))
        log.step("preparing")

        guard toolchain.findJava() != nil else {
            throw BuildError.missingTool("Java — install it with: " + Platform.installHint(.java))
        }
        guard toolchain.findMkgmap() != nil else {
            throw BuildError.missingTool("mkgmap — install it from the Toolchain screen")
        }
        // Copernicus and Viewfinder are read and converted in-process; pyhgtmap is needed
        // only by the sources that require an account.
        if recipe.needsElevationData, !credentialedSources.isEmpty,
           toolchain.findPyhgtmap() == nil {
            throw BuildError.missingTool(
                "pyhgtmap — needed for \(credentialedSources.joined(separator: ", "))."
                + " Install it from the Toolchain screen, or pick copernicus or view1/view3")
        }

        Paths.bootstrap()
        Paths.ensure(workDirectory)
        // The destination folder is created at the end, so a failed build leaves no
        // empty dated folder behind.

        let free = FileTools.freeSpaceBytes(at: Paths.root)
        if free > 0 && free < 8_000_000_000 {
            log.warn("only \(Fmt.bytes(free)) free on the volume holding ~/.kmap — large regions may not fit")
        }

        log.append("region:  \(recipe.mapName)  [\(recipe.regions.map(\.id).joined(separator: ", "))]")
        log.append("bbox:    \(recipe.coverage.display)")
        log.append("style:   \(recipe.style.name) · code page \(recipe.codePage)"
                   + (recipe.effectiveNameTagList.isEmpty ? "" : " · labels \(recipe.effectiveNameTagList)"))
        if recipe.codePage == CodePage.westernEuropean, recipe.coverage.isValid,
           recipe.coverage.minLon > CodePage.cyrillicMeridian {
            log.warn("code page 1252 cannot hold Cyrillic — names would be transliterated to Latin."
                     + " Set 1251 if this region's names are in Cyrillic.")
        }
        log.append("product: family \(recipe.familyID) · tiles from \(recipe.mapIDBase)")
        log.append("options: contours=\(recipe.contours ? "\(recipe.contourInterval) m" : "off")"
                   + "  dem=\(recipe.demLayer ? "on" : "off")"
                   + "  routable=\(recipe.routable)  index=\(recipe.searchIndex)")
        log.append("levels:  \(recipe.levels.name) — \(recipe.levels.levels)")
        log.append("work:    \(Paths.display(workDirectory))")
        log.append("output:  \(recipe.splitMode.label) → \(Paths.display(recipe.destinationDirectory))")
        // Unfinished downloads leave parts behind; nothing else removes them. The tools
        // folder too: a half-fetched data pack is the largest of them.
        let freed = PartFiles.sweepAbandoned(in: Paths.cache)
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
