import Foundation

/// Preferences that persist between builds.
final class SettingsScreen: Screen {
    var page: Page { Page(t("settings"), keys: keys) }

    private var keys: [Hint] {
        if picking != nil {
            return [
                Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("choose")),
                Hint(key: "esc", label: t("cancel"))
            ]
        }
        if let editing {
            var hints = [Hint(key: Glyph.enter, label: t("accept"))]
            if FilePicker.isAvailable, editing.wants != nil {
                hints.append(Hint(key: "^O", label: t("browse")))
            }
            hints.append(Hint(key: "esc", label: t("cancel")))
            return hints
        }
        return [
            Hint(key: "↑↓", label: t("field")),
            Hint(key: "←→", label: t("change")),
            Hint(key: Glyph.enter, label: t("edit")),
            Hint(key: "esc", label: t("save & back"))
        ]
    }

    var list = ListState()
    var editing: Field?
    var draft = ""
    var message: String?
    /// The open list: its field, its options, and the cursor in it.
    var picking: (field: Field, labels: [String], at: Int)?
    /// The row the open list hangs under.
    var pickerRow: Int?

    /// The login fields serve srtm1 and alos1, which need pyhgtmap.
    func fields(_ ctx: AppContext) -> [Field] {
        guard ctx.toolchain.findPyhgtmap() == nil else { return Field.allCases }
        return Field.allCases.filter { !$0.isLogin }
    }

    func tick(_ ctx: AppContext) {
        ctx.refreshOverview()
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if let field = editing { return handleEditing(field, key, ctx) }
        if picking != nil { return handlePicking(key, ctx) }

        let fields = fields(ctx)
        switch key.command {
        case .up, .char("k"): list.move(-1, count: fields.count)
        case .down, .char("j"): list.move(1, count: fields.count)
        case .left: adjust(fields[safe: list.selected], by: -1, ctx)
        case .right: adjust(fields[safe: list.selected], by: 1, ctx)
        case .esc:
            ctx.settings.save()
            return .pop
        case .ctrl("c"): return .quit
        case .enter:
            guard let field = fields[safe: list.selected] else { return .none }
            open(field, ctx)
        default: break
        }
        return .none
    }

    private func handleEditing(_ field: Field, _ key: KeyEvent, _ ctx: AppContext) -> Route {
        switch key {
        case .ctrl("o"):
            if let wanted = field.wants,
                let chosen = FilePicker.choose(wanted, startingAt: Paths.expand(draft), prompt: field.label)
            {
                draft = chosen.path
            }
        case .enter:
            commit(field, ctx)
            editing = nil
        case .esc: editing = nil
        case .backspace: if !draft.isEmpty { draft.removeLast() }
        case .char(let c): draft.append(c)
        case .paste(let text): draft += text.replacingOccurrences(of: "\n", with: "")
        default: break
        }
        return .none
    }

    private func handlePicking(_ key: KeyEvent, _ ctx: AppContext) -> Route {
        guard var open = picking else { return .none }
        switch key {
        case .up, .char("k"):
            open.at = (open.at - 1 + open.labels.count) % open.labels.count
            picking = open
        case .down, .char("j"), .tab:
            open.at = (open.at + 1) % open.labels.count
            picking = open
        case .enter, .char(" "):
            picking = nil
            choose(open.field, at: open.at, ctx)
        case .esc, .left, .char("h"), .ctrl("c"):
            picking = nil
        default: break
        }
        return .none
    }

    /// Enter: edit the text, clear the cache, or open the list.
    private func open(_ field: Field, _ ctx: AppContext) {
        switch field {
        case .clearCache:
            clearCache(ctx)
            ctx.refreshOverview(force: true)
        case .clearElevation:
            clearElevationCache(ctx)
            ctx.refreshOverview(force: true)
        default:
            if field.isText {
                editing = field
                draft = currentText(field, ctx)
            } else if let list = dropdown(field, ctx) {
                picking = (field, list.labels, list.at)
            } else {
                adjust(field, by: 1, ctx)
            }
        }
    }
}
