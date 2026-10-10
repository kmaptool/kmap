import Foundation

/// Runs a recipe end to end: extract, elevation, split, mkgmap, and the .img files.
/// Mutable state sits in `state` and is read through `snapshot()`, so the render loop
/// never blocks on the work.
final class BuildPipeline: Sendable {
    let log: Log
    let recipe: BuildRecipe
    let downloadProgress = DownloadProgress()

    let settings: SettingsStore
    let toolchain: Toolchain
    let styles: StyleCatalog

    var workDirectory: URL { recipe.workDirectory }

    /// Separate, so a progress monitor can hold the stages without holding the build.
    let board = StageBoard()

    /// A change that reads what it writes takes the lock once, not per field.
    let state = Locked(Run())

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
    var dataPacksForTesting: [DataPack]? {
        get { state.withLock { $0.dataPacksForTesting } }
        set { state.withLock { $0.dataPacksForTesting = newValue } }
    }
    var wasCancelled: Bool { state.withLock { $0.wasCancelled } }

    /// - Parameter showing: the lowest severity shown; the log file keeps everything.
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

    // MARK: The run

    func run() async {
        var locks: [HeldLock] = []
        do {
            Paths.ensure(Paths.locks)
            Self.removeOldLocks()
            // Held only by `locks`, so `locks = []` releases them before `finish`.
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
            // These wait only while an install swaps a tool in or a cache is cleared.
            let shared = [
                Toolchain.inUseLock, CacheClearing.inUseLock(elevation: false), CacheClearing.inUseLock(elevation: true)
            ]
            for lock in shared {
                if let held = HeldLock(trying: lock, shared: true) {
                    locks.append(held)
                    continue
                }
                log.append("waiting for an install or a cache clear to end")
                guard let held = await HeldLock.waiting(for: lock, shared: true) else { throw CancellationError() }
                locks.append(held)
            }
            try await preflight()
            try stopIfCancelled()
            try await updateDataPacks()
            try stopIfCancelled()
            // Before anything reads the cache: restores a copy a killed run put aside.
            for region in recipe.regions { Self.settleSuspect(besides: Paths.cachedExtract(forRegion: region.id)) }
            let extracts = try await downloadExtracts()
            try stopIfCancelled()
            do {
                try await buildMap(from: extracts)
            } catch  where Self.readsLikeADamagedExtract(error) {
                // A damaged extract is fetched again, once. The running elevation ends
                // first, or it would write the same stages as the new one.
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
            // The elevation may still write into the work folder: stop it before the lock
            // goes, or the next build of this region meets its files.
            await settleElevation(puttingStagesBack: false)
            // A folder this build did not make is an earlier build's.
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

    private func buildMap(from cached: [URL]) async throws {
        let extracts = pinning(cached)
        // Elevation runs beside the split. Only the first region's write waits on it, for
        // the contours, and the road repair waits on its tiles. A retried split awaits the
        // same task.
        let terrain = Gate<[URL]>()
        let elevationTask = Task { [self] in
            // Opened however the stage ends, so a waiting repair never hangs.
            defer { terrain.open(demSearchPaths()) }
            return try await buildElevation(extracts: extracts, terrain: terrain)
        }
        retain(elevation: elevationTask)
        defer { elevationTask.cancel() }
        // Node count only approximates drawing size, so the cap drops only after a tile
        // overflows the 16 MB drawing section.
        var cap = recipe.maxNodesPerTile
        // Only the tiles mkgmap names are cut; the cap is halved when it names none.
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
}
