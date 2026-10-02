import Foundation

/// Shared services and state handed to every screen: read each frame by the render loop
/// and written by background work hopping back through `MainActor.run`.
@MainActor
final class AppContext {
    /// Frames between samples of the machine load: a CPU rate needs a gap between readings.
    static let loadEvery = 10
    /// Frames between counts of the caches, and of the elevation cache, which is thousands
    /// of files and so is walked far less often.
    static let overviewEvery = 20
    static let elevationEvery = 300
    /// A frame no sampling has happened on yet.
    private static let never = -1000

    let settings: SettingsStore
    let theme: Theme
    let toolchain: Toolchain
    let styles: StyleCatalog
    let index = RegionIndex()

    var frame: Int = 0
    /// Set while the region index is loading, so screens can say why they are empty.
    var indexState: IndexState = .idle

    /// Snapshots taken off the render loop: probing the toolchain launches programs and
    /// counting the caches walks the filesystem.
    private(set) var tools: [ToolStatus] = []
    private(set) var toolsProbed = false
    private(set) var overview = Overview()
    /// What the mirrors offer for the data packs, by id. Empty until the toolchain
    /// screen asks.
    private(set) var packNews: [String: DataPack.News] = [:]
    private(set) var packsChecked = false
    /// Set while a patch from an older kmap is being rebuilt, so no install runs into it.
    private(set) var renewingPatch = false

    /// What the machine is doing, sampled for the header bar.
    private(set) var load = MachineLoad(cpu: nil, usedMemory: 0, totalMemory: 0)
    private var loadTicks: MachineLoad.Ticks?
    private var lastLoadFrame = AppContext.never
    private var lastOverviewFrame = AppContext.never
    private var lastElevationFrame = AppContext.never
    private var probing = false
    private var probeAgain = false
    private var askingPacks = false
    /// Set by the tests: the list is theirs, and no probe replaces it.
    private var toolsFrozen = false
    /// The same for the packs' news: no mirror is asked, and nothing overwrites it.
    private var packsFrozen = false

    struct Overview {
        var cachedExtracts = 0
        var cachedBytes: Int64 = 0
        var builtMaps = 0
        var elevation = Elevation()

        /// Cached elevation tiles, counted per source.
        struct Elevation {
            var tiles = 0
            var bytes: Int64 = 0
            var sources: [String] = []

            static func sample(_ root: URL = Paths.hgtCache) -> Elevation {
                var out = Elevation()
                var sources: Set<String> = []
                guard
                    let walker = FileManager.default.enumerator(
                        at: root,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                else { return out }
                for case let url as URL in walker where url.pathExtension.lowercased() == "hgt" {
                    out.tiles += 1
                    out.bytes += FileTools.size(of: url)
                    sources.insert(url.deletingLastPathComponent().lastPathComponent)
                }
                out.sources = sources.sorted()
                return out
            }
        }
    }

    enum IndexState: Equatable {
        case idle, loading, ready, failed(String)
    }

    init() {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        self.settings = settings
        self.theme = .strict
        self.toolchain = toolchain
        self.styles = StyleCatalog(settings: settings, toolchain: toolchain)
    }

    // MARK: The toolchain

    /// Probes the toolchain off the render loop. Cached until `force` asks again.
    func refreshTools(force: Bool = false) {
        guard !toolsFrozen else { return }
        // A forced ask during a probe is kept: the running probe read the folders
        // before whatever changed landed.
        if probing { probeAgain = probeAgain || force; return }
        if toolsProbed && !force { return }
        probing = true
        if force { toolchain.invalidate() }
        // Detached: a Task created here would inherit the main actor, and the probe
        // spawns processes.
        let toolchain = self.toolchain
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let probed = toolchain.status()
            await MainActor.run {
                self.tools = probed
                self.toolsProbed = true
                self.probing = false
                if self.probeAgain {
                    self.probeAgain = false
                    self.refreshTools(force: true)
                }
            }
        }
    }

    /// Rebuilds the mkgmap patch an older kmap left, off the render loop. Nothing happens
    /// where the patch was never installed.
    func renewPatchIfStale() {
        guard !toolsFrozen, !renewingPatch else { return }
        renewingPatch = true
        let toolchain = self.toolchain
        Task.detached(priority: .utility) { [weak self] in
            let renewed = toolchain.patchIsStale ? await toolchain.renewStalePatch(log: Log()) : false
            await MainActor.run { [weak self] in
                self?.renewingPatch = false
                if renewed { self?.refreshTools(force: true) }
            }
        }
    }

    /// Asks the mirrors about the installed packs, off the render loop. Not on the
    /// build's schedule, which can be `never`: opening the screen is the asking.
    func refreshPackNews(force: Bool = false) {
        guard !packsFrozen, !askingPacks else { return }
        if packsChecked && !force { return }
        askingPacks = true
        Task.detached(priority: .utility) { [weak self] in
            let found = await withTaskGroup(of: (String, DataPack.News?).self) { group in
                for pack in DataPack.all where pack.isInstalled {
                    group.addTask { (pack.id, await pack.newer()) }
                }
                var out: [String: DataPack.News] = [:]
                for await (id, news) in group { out[id] = news }
                return out.compactMapValues { $0 }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.packNews = found
                self.packsChecked = true
                self.askingPacks = false
            }
        }
    }

    /// A toolchain list of the test's own, which no probe replaces: what the machine
    /// happens to have installed says nothing about the screen.
    func useForTesting(tools: [ToolStatus]) {
        self.tools = tools
        toolsProbed = true
        toolsFrozen = true
    }

    /// What a check found, without making one: the screen is testable with no network.
    /// Frozen, as the tools are: a forced re-check after an install would otherwise ask
    /// the mirror, and an answer landing after the test ended has crashed the process.
    func useForTesting(packNews: [String: DataPack.News]) {
        self.packNews = packNews
        packsChecked = true
        packsFrozen = true
    }

    // MARK: The machine and the caches

    func refreshLoad() {
        guard frame - lastLoadFrame >= AppContext.loadEvery else { return }
        lastLoadFrame = frame
        let (sample, ticks) = MachineLoad.read(since: loadTicks)
        loadTicks = ticks
        // A reading with no rate yet keeps the previous CPU figure rather than showing 0.
        load = MachineLoad(
            cpu: sample.cpu ?? load.cpu,
            usedMemory: sample.usedMemory,
            totalMemory: sample.totalMemory
        )
    }

    /// Re-counts cached extracts and built maps off the render loop. `force` bypasses the
    /// rate limits, for use after something is deleted.
    func refreshOverview(force: Bool = false) {
        guard force || frame - lastOverviewFrame > AppContext.overviewEvery else { return }
        lastOverviewFrame = frame
        let walkElevation = force || frame - lastElevationFrame > AppContext.elevationEvery
        if walkElevation { lastElevationFrame = frame }
        let previousElevation = overview.elevation
        let outputURL = settings.settings.outputURL
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let extracts = FileTools.contents(of: Paths.pbfCache, extension: "pbf")
            let snapshot = Overview(
                cachedExtracts: extracts.count,
                cachedBytes: extracts.reduce(Int64(0)) { $0 + FileTools.size(of: $1) },
                builtMaps: BuiltMaps.outputs(under: outputURL).count,
                elevation: walkElevation ? Overview.Elevation.sample() : previousElevation
            )
            await MainActor.run { self.overview = snapshot }
        }
    }

    // MARK: The region index

    /// Kicks off the index load once; safe to call from any screen's `tick`. A failed
    /// load stays failed until `force`, since screens call this every frame.
    func loadIndexIfNeeded(force: Bool = false) {
        if case .loading = indexState { return }
        if case .ready = indexState, !force { return }
        if case .failed = indexState, !force { return }
        indexState = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.index.load(forceRefresh: force)
                self.indexState = .ready
            } catch {
                self.indexState = .failed(error.localizedDescription)
            }
        }
    }
}
