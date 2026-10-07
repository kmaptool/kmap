import Foundation

/// The panel beside the menu: what the machine has, and what the selected entry is for.
struct MainMenuStatusPanel {
    let selected: MainMenuScreen.Item?

    private static let labelColumn = 14

    @MainActor
    func draw(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y
        s.sectionRule(
            rect,
            y,
            t("state"),
            labelStyle: Style(fg: theme.dim, bg: theme.appBg),
            ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
        )
        y += 2

        func line(_ label: String, _ value: String, tone: Color? = nil) {
            guard y < rect.maxY else { return }
            s.text(rect.x, y, label, Style(fg: theme.faint, bg: theme.appBg), limit: Self.labelColumn)
            s.text(
                rect.x + Self.labelColumn,
                y,
                truncate(value, to: max(0, rect.w - Self.labelColumn)),
                Style(fg: tone ?? theme.text, bg: theme.appBg)
            )
            y += 1
        }

        switch ctx.indexState {
        case .idle, .loading:
            line(t("regions"), t("loading %@", String(Widgets.spinner(ctx.frame))), tone: theme.dim)
        case .ready:
            line(t("regions"), t("%d available", ctx.index.regions.count), tone: theme.ok)
        case .failed(let message):
            line(t("regions"), truncate(message, to: rect.w - Self.labelColumn - 1), tone: theme.danger)
        }

        if !ctx.toolsProbed {
            line(t("toolchain"), t("checking %@", String(Widgets.spinner(ctx.frame))), tone: theme.dim)
        } else {
            let ready = ctx.tools.filter(\.isReady).count
            line(
                t("toolchain"),
                t("%d/%d ready", ready, ctx.tools.count),
                tone: ready == ctx.tools.count ? theme.ok : theme.warn
            )
            y = drawMissingTools(ctx.tools, into: s, rect: rect, y: y, theme: theme)
        }

        line(t("output"), Paths.display(ctx.settings.settings.outputURL))
        let overview = ctx.overview
        line(
            t("cache"),
            !overview.cachedAny
                ? t("empty")
                : tn("%d extract(s)", overview.cachedExtracts) + " · \(Fmt.bytes(overview.cachedBytes))"
        )
        line(t("built maps"), overview.builtMaps == 0 ? t("none yet") : "\(overview.builtMaps)")

        y += 1
        guard y < rect.maxY - 1, let item = selected else { return }
        drawAbout(item, into: s, rect: rect, y: y, theme: theme)
    }

    private func drawMissingTools(_ tools: [ToolStatus], into s: Surface, rect: Rect, y: Int, theme: Theme) -> Int {
        var y = y
        for tool in tools where !tool.isReady {
            guard y < rect.maxY else { break }
            s.text(
                rect.x + Self.labelColumn,
                y,
                truncate("\(Glyph.cross) " + t("%@ missing", tool.name), to: max(0, rect.w - Self.labelColumn)),
                Style(fg: theme.warn, bg: theme.appBg)
            )
            y += 1
        }
        return y
    }

    /// The description of the entry under the cursor.
    private func drawAbout(_ item: MainMenuScreen.Item, into s: Surface, rect: Rect, y: Int, theme: Theme) {
        s.sectionRule(
            rect,
            y,
            item.label.lowercased(),
            labelStyle: Style(fg: theme.dim, bg: theme.appBg),
            ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
        )
        s.paragraph(
            item.about,
            x: rect.x,
            y: y + 2,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg),
            maxY: rect.maxY
        )
    }
}
