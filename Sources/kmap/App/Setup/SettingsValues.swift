import Foundation

/// Reading and writing the settings behind the rows.
extension SettingsScreen {
    /// Heap sizes in GB; 0 derives it from the machine's memory.
    static let heapChoices = [0, 2, 4, 6, 8, 12, 16, 20, 24, 32, 48, 64]
    /// Nodes per tile: smaller tiles build faster and there are more of them.
    static let nodeChoices = [800_000, 1_200_000, 1_600_000, 2_000_000, 2_400_000]
    static let defaultNodeChoice = 2
    private static let connectionRange = 1...PartFiles.maxParts

    func currentText(_ field: Field, _ ctx: AppContext) -> String {
        let s = ctx.settings.settings
        switch field {
        case .output: return s.outputDirectory
        case .work: return s.workDirectory
        case .usgsUser, .jaxaUser: return ElevationLogins.load(field.service ?? .srtm).user
        // Never put on screen: typed afresh, and nothing typed keeps it.
        case .usgsPassword, .jaxaPassword: return ""
        case .mkgmapJar: return s.mkgmapJar
        case .javaBinary: return s.javaBinary
        default: return ""
        }
    }

    func commit(_ field: Field, _ ctx: AppContext) {
        let value = draft.trimmingCharacters(in: .whitespaces)
        // Logins live in pyhgtmap's file, not in the settings.
        if let service = field.service {
            if field.isPassword, draft.isEmpty { return }
            let login = ElevationLogins.load(service)
            do {
                switch field {
                case .usgsUser, .jaxaUser: try ElevationLogins.save(service, user: value, password: login.password)
                // As typed: edge spaces may be part of the password.
                default: try ElevationLogins.save(service, user: login.user, password: draft)
                }
                message = t("saved")
                verifyLogin(service)
            } catch {
                refuse(t("could not save the login: %@", error.localizedDescription))
            }
            return
        }
        // Kept as typed, so a folder relative to where kmap started would be another one
        // for each kmap started elsewhere.
        if field == .output || field == .work, !value.isEmpty, !Paths.isFullPath(value) {
            refuse(t("%@ is not a full path — start it at the root or with ~", value))
            return
        }
        let saved = ctx.settings.update { settings in
            switch field {
            case .output: if !value.isEmpty { settings.outputDirectory = value }
            case .work: settings.workDirectory = value.isEmpty ? Paths.work.path : value
            case .mkgmapJar: settings.mkgmapJar = value
            case .javaBinary: settings.javaBinary = value
            default: break
            }
        }
        switch saved {
        case .success:
            message = t("saved")
            // The tools found before are found again, or the old ones run until a restart.
            if field == .mkgmapJar || field == .javaBinary { ctx.refreshTools(force: true) }
        case .failure(let error): refuse(t("could not save the settings: %@", error.localizedDescription))
        }
    }

    private func verifyLogin(_ service: ElevationLogins.Service) {
        let login = ElevationLogins.load(service)
        guard !login.user.isEmpty, !login.password.isEmpty else { return }
        message = t("%@ — checking the login…", service.displayName)
        Task { [weak self] in
            let verdict = await ElevationLogins.verify(service)
            await MainActor.run {
                guard let self else { return }
                switch verdict {
                case .valid: self.message = t("%@ — the login works", service.displayName)
                case .rejected: self.refuse(t("%@ refused these credentials", service.displayName))
                case .unreachable:
                    self.refuse(t("%@ did not answer — the login is left as it was", service.displayName))
                }
            }
        }
    }

    /// The values a row offers and the index of the current one; nil where the answer
    /// is free text.
    func dropdown(_ field: Field, _ ctx: AppContext) -> (labels: [String], at: Int)? {
        let settings = ctx.settings.settings
        switch field {
        case .uiLanguage:
            return (Lang.allCases.map(\.nativeName), Lang.allCases.firstIndex(of: L10n.current) ?? 0)
        case .connections:
            let range = Self.connectionRange
            return (
                range.map { "\($0)" },
                max(0, min(range.count - 1, settings.downloadConnections - range.lowerBound))
            )
        case .toolchainUpdates:
            return (
                ToolchainUpdates.allCases.map(\.title),
                ToolchainUpdates.allCases.firstIndex(of: settings.toolchainUpdates) ?? 0
            )
        case .heap:
            let labels = Self.heapChoices.map {
                $0 == 0 ? t("auto (%d GB)", settings.resolvedHeapGB) : "\($0) GB"
            }
            return (labels, Self.heapChoices.firstIndex(of: settings.javaHeapGB) ?? 0)
        case .maxNodes:
            return (
                Self.nodeChoices.map { "\($0 / 1000)k" },
                Self.nodeChoices.firstIndex(of: settings.maxNodesPerTile) ?? Self.defaultNodeChoice
            )
        case .keepWork:
            return ([t("off"), t("on")], settings.keepWorkFiles ? 1 : 0)
        default:
            return nil
        }
    }

    func choose(_ field: Field, at index: Int, _ ctx: AppContext) {
        message = nil
        if field == .uiLanguage {
            if let language = Lang.allCases[safe: index] { use(language, ctx) }
            return
        }
        let saved = ctx.settings.update { s in
            switch field {
            case .connections:
                let range = Self.connectionRange
                s.downloadConnections = max(range.lowerBound, min(range.upperBound, index + 1))
            case .toolchainUpdates:
                s.toolchainUpdates = ToolchainUpdates.allCases[safe: index] ?? .monthly
            case .heap: s.javaHeapGB = Self.heapChoices[safe: index] ?? 0
            case .maxNodes:
                s.maxNodesPerTile = Self.nodeChoices[safe: index] ?? Self.nodeChoices[Self.defaultNodeChoice]
            case .keepWork: s.keepWorkFiles = index == 1
            default: break
            }
        }
        if case .failure(let error) = saved { refuse(t("could not save the settings: %@", error.localizedDescription)) }
    }

    /// One step along the row's list. The language and the switch wrap; the rest stop
    /// at their ends.
    func adjust(_ field: Field?, by delta: Int, _ ctx: AppContext) {
        guard let field, let open = dropdown(field, ctx) else { return }
        let count = open.labels.count
        let wraps = field == .uiLanguage || field == .keepWork
        let at = wraps ? ((open.at + delta) % count + count) % count : max(0, min(count - 1, open.at + delta))
        choose(field, at: at, ctx)
    }

    func dropdownForTesting(_ field: Field, _ ctx: AppContext) -> (labels: [String], at: Int)? {
        dropdown(field, ctx)
    }

    func chooseForTesting(_ field: Field, at index: Int, _ ctx: AppContext) {
        choose(field, at: index, ctx)
    }

    /// Applied at once, so the labels redraw in the language chosen.
    private func use(_ language: Lang, _ ctx: AppContext) {
        L10n.use(language, in: ctx.settings)
        message = t("saved")
    }

    /// Asks before emptying a cache, and refuses while a build or a download may be
    /// reading or writing it.
    func askToClear(_ field: Field, _ ctx: AppContext) {
        let elevation = field == .clearElevation
        // The folder as it is now, parts of a stopped download included: the overview
        // counts finished files only, and late.
        let folder = elevation ? Paths.hgtCache : Paths.pbfCache
        // Through a link at the root: macOS will not list a folder by its link's path.
        guard !FileTools.contents(of: FileTools.resolvingLinks(folder)).isEmpty else {
            message = t("the cache is empty — nothing to clear")
            return
        }
        // Summed once, on the key: the overview's figure is late, 0 before its first walk, and
        // counts finished tiles only. What the clearing will empty, links it follows included.
        let held = Self.emptied(folder, elevation: elevation).reduce(Int64(0)) {
            $0 + Self.tally($1, elevation: elevation).bytes
        }
        guard !Self.buildOrDownloadRunning() else {
            refuse(t("a build or a download is running — clear the cache once it ends"))
            return
        }
        let size = Fmt.bytes(held)
        asking = Question(
            dialog: Dialog(
                title: t("Clear the cache"),
                body: [
                    elevation
                        ? t(
                            "%@ of elevation tiles will be deleted. A build fetches them again, which can take hours.",
                            size
                        )
                        : t("%@ of downloaded extracts will be deleted. A build downloads them again.", size)
                ],
                confirm: t("clear"),
                cancel: t("cancel")
            ),
            subject: field
        )
    }

    func clear(_ field: Field, _ ctx: AppContext) {
        guard !Self.buildOrDownloadRunning() else {
            refuse(t("a build or a download is running — clear the cache once it ends"))
            return
        }
        // Off the render loop: a cache of tens of gigabytes takes a while to size and empty.
        message = t("clearing…")
        let elevation = field == .clearElevation
        let cache = elevation ? Paths.hgtCache : Paths.pbfCache
        let plan = Self.setAside(cache, elevation: elevation)
        Task { @MainActor [weak self] in
            let said = await Task.detached(priority: .utility) {
                Self.clear(plan, elevation: elevation)
            }.value
            self?.message = said
            ctx.refreshOverview(force: true)
        }
    }

    /// Whether any kmap holds a build's work lock or a download's.
    static func buildOrDownloadRunning(in locks: URL = Paths.locks) -> Bool {
        FileTools.contents(of: locks).contains { lock in
            let name = lock.lastPathComponent
            guard name.hasPrefix(BuildPipeline.workLockPrefix) || name.hasPrefix("download-") else { return false }
            return HeldLock(trying: lock) == nil
        }
    }

    /// The folders a clear empties: the cache, and in the elevation cache each source
    /// folder linked elsewhere, another disk say. A link among the extracts is the
    /// person's own and is left as it is.
    /// Each once, and none inside the cache, which goes with it.
    nonisolated static func emptied(_ cache: URL, elevation: Bool) -> [URL] {
        let root = FileTools.resolvingLinks(cache)
        var out = [root]
        for folder in elevation ? linkedFolders(in: root) : []
        where !out.contains(folder) && !folder.path.hasPrefix(root.path + "/") {
            out.append(folder)
        }
        return out
    }

    nonisolated private static func linkedFolders(in folder: URL) -> [URL] {
        let inside = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return inside.filter { FileTools.isDirectory($0) && !FileTools.isDirectoryItself($0) }
            .map(FileTools.resolvingLinks)
    }

    /// Files and bytes under a folder, links not followed: tiles alone in the elevation cache.
    nonisolated static func tally(_ folder: URL, elevation: Bool) -> (files: Int, bytes: Int64) {
        let files = FileTools.allFiles(under: folder, extension: elevation ? "hgt" : nil)
        return (files.count, files.reduce(Int64(0)) { $0 + FileTools.size(of: $1) })
    }

    /// Set aside: renamed, to be deleted whole. In place: emptied where it is.
    typealias ClearPlan = (aside: [URL], inPlace: [URL])

    private nonisolated static let clearingMark = "-kmap-clearing-"
    /// Folders set aside and not yet deleted, which a sweep for leftovers leaves alone.
    private nonisolated static let underway = Locked<Set<String>>([])

    /// Renames each folder a clear empties and puts an empty one in its place, so a build
    /// started meanwhile finds nothing rather than files going from under it, and a second
    /// clear finds the new folder. A folder that will not rename, a mount point or one on
    /// another volume than its parent, is emptied in place; a link to it stays.
    static func setAside(_ cache: URL, elevation: Bool) -> ClearPlan {
        var plan: ClearPlan = ([], [])
        for folder in emptied(cache, elevation: elevation) {
            if let aside = renameAside(folder) {
                plan.aside.append(aside)
            } else {
                plan.inPlace.append(folder)
            }
        }
        return plan
    }

    private static func renameAside(_ folder: URL) -> URL? {
        let parent = folder.deletingLastPathComponent()
        guard FileTools.sameVolume(folder, parent) else { return nil }
        let aside = parent.appendingPathComponent(
            ".\(folder.lastPathComponent)\(clearingMark)\(UUID().uuidString.prefix(8))"
        )
        // The links inside stay with the new folder.
        let links = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileTools.isDirectory($0) && !FileTools.isDirectoryItself($0) }
        // Marked before it exists, so no other clear's sweep takes it.
        underway.withLock { _ = $0.insert(aside.path) }
        guard (try? FileTools.rename(folder, to: aside)) != nil else {
            underway.withLock { _ = $0.remove(aside.path) }
            return nil
        }
        Paths.ensure(folder)
        for link in links {
            try? FileTools.rename(aside.appendingPathComponent(link.lastPathComponent), to: link)
        }
        return aside
    }

    /// Deletes what `setAside` planned, with any folder an earlier clear left when kmap was
    /// quit, and says what went: what was there less what is left.
    nonisolated static func clear(_ plan: ClearPlan, elevation: Bool) -> String {
        let folders = plan.aside + plan.inPlace
        let before = folders.map { tally($0, elevation: elevation) }
        for folder in plan.inPlace { emptyKeepingLinks(folder) }
        for folder in plan.aside {
            FileTools.removeIfPresent(folder)
            underway.withLock { _ = $0.remove(folder.path) }
            sweepLeftovers(beside: folder)
        }
        let after = folders.map { FileTools.exists($0) ? tally($0, elevation: elevation) : (files: 0, bytes: Int64(0)) }
        var files = 0
        var bytes: Int64 = 0
        for (was, left) in zip(before, after) {
            files += was.files - left.files
            bytes += was.bytes - left.bytes
        }
        let size = Fmt.bytes(bytes)
        return elevation ? tn("cleared %d tile(s), %@", files, size) : tn("cleared %d file(s), %@", files, size)
    }

    /// A link to a folder is the clear's to empty on its own, and stays.
    nonisolated private static func emptyKeepingLinks(_ folder: URL) {
        let inside = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in inside where !(FileTools.isDirectory(item) && !FileTools.isDirectoryItself(item)) {
            FileTools.removeIfPresent(item)
        }
    }

    nonisolated private static func sweepLeftovers(beside folder: URL) {
        let name = folder.lastPathComponent
        guard let mark = name.range(of: clearingMark, options: .backwards) else { return }
        let stem = name[..<mark.upperBound]
        let near =
            (try? FileManager.default.contentsOfDirectory(
                at: folder.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            )) ?? []
        let busy = underway.withLock { $0 }
        for left in near where left.lastPathComponent.hasPrefix(stem) && !busy.contains(left.path) {
            FileTools.removeIfPresent(left)
        }
    }
}
