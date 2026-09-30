import Foundation

/// Drawing the settings: a row per field with its help under it, and the open list.
extension SettingsScreen {
    private static let helpIndent = 20
    private static let passwordMaskLimit = 12

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let fields = fields(ctx)
        // Two rows a field; the window keeps the selected one on a short terminal.
        let visible = max(1, rect.h / 2)
        pickerRow = nil

        var y = rect.y
        for i in list.window(count: fields.count, visible: visible) {
            let field = fields[i]
            guard y + 1 < rect.maxY else { break }
            Widgets.field(
                s,
                rect: rect,
                y: y,
                label: field.label,
                value: value(for: field, ctx),
                theme: theme,
                labelWidth: Layout.fieldLabel,
                selected: i == list.selected
            )
            if field == picking?.field { pickerRow = y }
            y += 1
            s.text(
                rect.x + Self.helpIndent,
                y,
                field.help,
                Style(fg: theme.faint, bg: theme.appBg),
                limit: max(0, rect.w - Self.helpIndent)
            )
            y += 1
        }

        Widgets.scrollHint(s, rect: rect, offset: list.offset, count: fields.count, visible: visible, theme: theme)
        if let message, y < rect.maxY {
            s.text(rect.x + 2, y, message, Style(fg: theme.ok, bg: theme.appBg))
        }
    }

    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        guard let open = picking, let row = pickerRow else { return }
        Widgets.optionList(
            s,
            within: rect,
            anchorRow: row,
            options: open.labels,
            at: open.at,
            theme: ctx.theme,
            indent: Self.helpIndent
        )
    }

    private func value(for field: Field, _ ctx: AppContext) -> String {
        if editing == field { return draft + "▏" }
        let settings = ctx.settings.settings
        switch field {
        case .uiLanguage: return L10n.current.nativeName
        case .output: return Paths.display(settings.outputURL)
        case .work: return Paths.display(settings.workURL)
        case .usgsUser, .jaxaUser:
            let user = ElevationLogins.load(field.service ?? .srtm).user
            return user.isEmpty ? t("not set — 3 arc-second data only") : user
        case .usgsPassword, .jaxaPassword:
            let stored = ElevationLogins.load(field.service ?? .srtm).password
            return stored.isEmpty
                ? t("not set") : String(repeating: "•", count: min(Self.passwordMaskLimit, stored.count))
        case .connections: return "\(settings.downloadConnections)"
        case .toolchainUpdates: return settings.toolchainUpdates.title
        case .heap:
            return settings.javaHeapGB == 0
                ? t("auto (%d GB)", settings.resolvedHeapGB) : "\(settings.javaHeapGB) GB"
        case .maxNodes: return "\(settings.maxNodesPerTile / 1000)k"
        case .keepWork: return settings.keepWorkFiles ? t("on") : t("off")
        case .mkgmapJar:
            guard settings.mkgmapJar.isEmpty else { return settings.mkgmapJar }
            return ctx.toolchain.findMkgmap().map { Paths.display($0.url) } ?? t("not found")
        case .javaBinary:
            guard settings.javaBinary.isEmpty else { return settings.javaBinary }
            return ctx.toolchain.findJava()?.path ?? t("not found")
        case .clearCache:
            let overview = ctx.overview
            guard overview.cachedExtracts > 0 else { return t("empty") }
            return tn("%d file(s)", overview.cachedExtracts)
                + " · \(Fmt.bytes(overview.cachedBytes)) — " + t("⏎ to clear")
        case .clearElevation:
            let cache = ctx.overview.elevation
            guard cache.tiles > 0 else { return t("empty") }
            return tn("%d tile(s)", cache.tiles) + " · \(Fmt.bytes(cache.bytes))"
                + " · \(cache.sources.joined(separator: " ")) — " + t("⏎ to clear")
        }
    }
}
