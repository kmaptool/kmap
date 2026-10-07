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
        guard !Self.clearing.contains(field) else {
            message = t("clearing…")
            return
        }
        let elevation = field == .clearElevation
        let folder = elevation ? Paths.hgtCache : Paths.pbfCache
        // Counted on the key: the overview may be late.
        let found = CacheClearing.preview(folder, elevation: elevation)
        guard found.any else {
            message = t("the cache is empty — nothing to clear")
            return
        }
        let held = found.bytes
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
        // 1 clear at a time per cache.
        guard Self.clearing.insert(field).inserted else { return }
        let elevation = field == .clearElevation
        let cache = elevation ? Paths.hgtCache : Paths.pbfCache
        // Held while the files go, so no build starts on them meanwhile.
        Paths.ensure(Paths.locks)
        // Asked again under the lock: one may have started since the question.
        guard let inUse = HeldLock(trying: CacheClearing.inUseLock(elevation: elevation)), inUse.isHeld,
            !Self.buildOrDownloadRunning()
        else {
            Self.clearing.remove(field)
            refuse(t("a build or a download is running — clear the cache once it ends"))
            return
        }
        Task { @MainActor [weak self] in
            let gone = await Task.detached(priority: .utility) {
                withExtendedLifetime(inUse) { CacheClearing.clear(cache, elevation: elevation) }
            }.value
            Self.clearing.remove(field)
            self?.message = Self.cleared(gone, elevation: elevation)
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

    private static var clearing: Set<Field> = []

    nonisolated static func cleared(_ gone: (files: Int, bytes: Int64), elevation: Bool) -> String {
        let size = Fmt.bytes(gone.bytes)
        return elevation
            ? tn("cleared %d tile(s), %@", gone.files, size) : tn("cleared %d extract(s), %@", gone.files, size)
    }
}
