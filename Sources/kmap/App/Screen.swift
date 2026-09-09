import Foundation

/// What a screen wants the navigator to do after handling a key.
enum Route {
    case none
    case push(Screen)
    case pop
    case popToRoot
    case replace(Screen)
    case quit
}

/// Shared services and state handed to every screen: read each frame by the render loop
/// and written by background work hopping back through `MainActor.run`.
@MainActor
final class AppContext {
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

    /// What the machine is doing, sampled about once a second for the header bar.
    private(set) var load = MachineLoad(cpu: nil, usedMemory: 0, totalMemory: 0)
    private var loadTicks: MachineLoad.Ticks?
    private var lastLoadFrame = -1000
    private var probing = false
    private var lastOverviewFrame = -1000
    private var lastElevationFrame = -1000

    struct Overview {
        var cachedExtracts = 0
        var cachedBytes: Int64 = 0
        var builtMaps = 0
        var elevation = Elevation()

        /// Cached elevation tiles, counted per source. Sampling stats every tile in the
        /// cache, so it is done rarely.
        struct Elevation {
            var tiles = 0
            var bytes: Int64 = 0
            var sources: [String] = []

            static func sample(_ root: URL = Paths.hgtCache) -> Elevation {
                var out = Elevation()
                var sources: Set<String> = []
                guard let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else { return out }
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

    /// Probes the toolchain off the render loop. Cheap after the first call — the results
    /// are cached until `refreshTools(force:)` is asked to redo them.
    func refreshTools(force: Bool = false) {
        guard !probing else { return }
        if toolsProbed && !force { return }
        probing = true
        if force { toolchain.invalidate() }
        // Detached, since a Task created here would inherit the main actor and
        // `toolchain.status()` spawns processes.
        let toolchain = self.toolchain
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let probed = toolchain.status()
            await MainActor.run {
                self.tools = probed
                self.toolsProbed = true
                self.probing = false
            }
        }
    }

    /// What the mirrors offer for the data packs, by id. Empty until the toolchain
    /// screen asks.
    private(set) var packNews: [String: DataPack.News] = [:]
    private(set) var packsChecked = false
    private var askingPacks = false

    /// Asks the mirrors about the installed packs, off the render loop. Not on the
    /// build's schedule, which can be `never`: opening the screen is the asking.
    func refreshPackNews(force: Bool = false) {
        guard !askingPacks else { return }
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

    /// What a check found, without making one: the screen is testable with no network.
    func useForTesting(packNews: [String: DataPack.News]) {
        self.packNews = packNews
        packsChecked = true
    }

    /// Samples CPU and memory for the header, about once a second: a CPU rate needs a gap
    /// between readings.
    func refreshLoad() {
        guard frame - lastLoadFrame >= 10 else { return }
        lastLoadFrame = frame
        let (sample, ticks) = MachineLoad.read(since: loadTicks)
        loadTicks = ticks
        // A reading with no rate yet keeps the previous CPU figure rather than showing 0.
        load = MachineLoad(cpu: sample.cpu ?? load.cpu,
                           usedMemory: sample.usedMemory, totalMemory: sample.totalMemory)
    }

    /// Re-counts cached extracts and built maps off the render loop. `force` bypasses the
    /// rate limits, for use after something is deleted.
    func refreshOverview(force: Bool = false) {
        guard force || frame - lastOverviewFrame > 20 else { return }
        lastOverviewFrame = frame
        // The elevation cache is thousands of files, so it is walked far less often.
        let walkElevation = force || frame - lastElevationFrame > 300
        if walkElevation { lastElevationFrame = frame }
        let previousElevation = overview.elevation
        let outputURL = settings.settings.outputURL
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let extracts = FileTools.contents(of: Paths.pbfCache, extension: "pbf")
            let bytes = extracts.reduce(Int64(0)) { $0 + FileTools.size(of: $1) }
            var built = FileTools.contents(of: outputURL, extension: "img").count
            for entry in FileTools.contents(of: outputURL) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                built += FileTools.contents(of: entry, extension: "img").count
            }
            let snapshot = Overview(
                cachedExtracts: extracts.count,
                cachedBytes: bytes,
                builtMaps: built,
                elevation: walkElevation ? Overview.Elevation.sample() : previousElevation)
            await MainActor.run { self.overview = snapshot }
        }
    }

    /// Kicks off the index load once; safe to call from any screen's `tick`.
    func loadIndexIfNeeded(force: Bool = false) {
        if case .loading = indexState { return }
        if case .ready = indexState, !force { return }
        // A failed load stays failed until `force`, since screens call this every frame.
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

/// A footer hint shown in the bottom bar.
struct Hint {
    let key: String
    let label: String
}

/// A screen's title and footer keys, declared in one place.
struct Page {
    /// The screen's own name.
    var name: String
    /// What it is showing at this moment, or nil where the screen is only ever itself.
    var subject: String?
    /// The footer keys, in the order they are offered.
    var keys: [Hint]

    init(_ name: String, subject: String? = nil, keys: [Hint] = []) {
        self.name = name
        self.subject = subject
        self.keys = keys
    }

    /// Name and subject, separated by a middle dot.
    var title: String {
        guard let subject, !subject.isEmpty else { return name }
        return "\(name) · \(subject)"
    }
}

/// One full-screen view in the navigation stack. Main-actor isolated, like the render
/// loop that drives it.
@MainActor
protocol Screen: AnyObject {
    /// The screen's title and footer keys.
    var page: Page { get }

    /// Called every frame before rendering, for polling background state.
    func tick(_ ctx: AppContext)

    /// Draws the screen within `rect`.
    func render(into surface: Surface, rect: Rect, ctx: AppContext)

    /// Draws anything that must cover the whole screen, such as an open dropdown, in a
    /// second pass after the header, content and footer.
    func renderOverlay(into surface: Surface, rect: Rect, ctx: AppContext)

    /// Handles a key and optionally requests navigation.
    func handle(_ key: KeyEvent, ctx: AppContext) -> Route

    /// Whether this screen wants pointer reports. Off by default: while they are on, the
    /// terminal's own text selection is disabled.
    var wantsMouse: Bool { get }
}

extension Screen {
    var title: String { page.title }
    var footerHints: [Hint] { page.keys }

    func tick(_ ctx: AppContext) {}
    func renderOverlay(into surface: Surface, rect: Rect, ctx: AppContext) {}
    var wantsMouse: Bool { false }
}
