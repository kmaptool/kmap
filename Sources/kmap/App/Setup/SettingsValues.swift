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
        case .usgsPassword, .jaxaPassword: return ElevationLogins.load(field.service ?? .srtm).password
        case .mkgmapJar: return s.mkgmapJar
        case .javaBinary: return s.javaBinary
        default: return ""
        }
    }

    func commit(_ field: Field, _ ctx: AppContext) {
        let value = draft.trimmingCharacters(in: .whitespaces)
        // Logins live in pyhgtmap's file, not in the settings.
        if let service = field.service {
            let login = ElevationLogins.load(service)
            do {
                switch field {
                case .usgsUser, .jaxaUser: try ElevationLogins.save(service, user: value, password: login.password)
                default: try ElevationLogins.save(service, user: login.user, password: value)
                }
                message = t("saved")
                verifyLogin(service)
            } catch {
                message = t("could not save the login: %@", error.localizedDescription)
            }
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
        case .success: message = t("saved")
        case .failure(let error): message = t("could not save the settings: %@", error.localizedDescription)
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
                case .rejected: self.message = t("%@ refused these credentials", service.displayName)
                case .unreachable:
                    self.message = t("%@ did not answer — the login is left as it was", service.displayName)
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
        ctx.settings.update { s in
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

    func clearCache(_ ctx: AppContext) {
        let files = FileTools.contents(of: Paths.pbfCache)
        let bytes = files.reduce(Int64(0)) { $0 + FileTools.size(of: $1) }
        FileTools.emptyDirectory(Paths.pbfCache)
        message = tn("cleared %d file(s), %@", files.count, Fmt.bytes(bytes))
    }

    func clearElevationCache(_ ctx: AppContext) {
        let before = AppContext.Overview.Elevation.sample()
        FileTools.emptyDirectory(Paths.hgtCache)
        message = tn("cleared %d tile(s), %@", before.tiles, Fmt.bytes(before.bytes))
    }
}
