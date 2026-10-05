import Foundation

/// One style: its identity, its coverage, and a way into each part of it. Coverage
/// compares the codes the rule set emits against the sections the TYP styles.
final class StyleDetailScreen: Screen {
    var page: Page { Page(document.style.name, keys: keys) }

    private var keys: [Hint] {
        var hints = [Hint(key: "↑↓", label: t("move")), Hint(key: Glyph.enter, label: t("open"))]
        if !document.isEditable, document.isReadable {
            hints.append(Hint(key: "^F", label: t("editable copy")))
        }
        if !isDefault { hints.append(Hint(key: "d", label: t("make default"))) }
        if recoverableMap != nil { hints.append(Hint(key: "r", label: t("recover from its map"))) }
        hints.append(Hint(key: "esc", label: t("back")))
        return hints
    }

    enum Row {
        case kind(MapElementKind)
        case drawOrder
    }

    /// The map this TYP was extracted from, while that path resolves.
    let recoverableMap: URL?
    /// Read again before each screen it opens: the one opened before may have saved, and
    /// a copy from when this screen opened would undo that at the next save.
    private(set) var document: StyleDocument
    var list = ListState()
    var message: String?
    var isDefault = false

    init(style: MapStyle) {
        document = StyleDocument.load(style)
        if case .importedTYP(let typ) = style.origin {
            recoverableMap = TypLibrary.importedSource(of: typ)
        } else {
            recoverableMap = nil
        }
    }

    var rows: [Row] {
        guard document.isReadable else { return [] }
        return MapElementKind.allCases.map(Row.kind) + [.drawOrder]
    }

    func tick(_ ctx: AppContext) {
        isDefault = ctx.settings.settings.defaultStyleID == document.style.id
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let rows = self.rows
        switch key.command {
        case .up: list.move(-1, count: rows.count)
        case .down: list.move(1, count: rows.count)
        case .enter:
            let selected = rows[safe: list.selected]
            if selected != nil { document = StyleDocument.load(document.style) }
            switch selected {
            case .kind(let kind): return .push(TypeBrowserScreen(document: document, kind: kind))
            case .drawOrder: return .push(DrawOrderScreen(document: document))
            case nil: return .none
            }
        case .char("d"):
            ctx.settings.update { $0.defaultStyleID = document.style.id }
            message = t("%@ is now the default", document.style.name)
        case .ctrl("f"):
            return adopt(ctx)
        case .char("r"):
            guard let img = recoverableMap, let typ = document.sourceURL else { return .none }
            return .push(RecoverScreen(img: img, typ: typ))
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// An editable copy in the library. A built-in's working copy is rewritten from the
    /// shipped asset whenever a build finds the two differ, so an edit there would be undone.
    private func adopt(_ ctx: AppContext) -> Route {
        guard let text = document.source?.text, !document.isEditable else { return .none }
        do {
            let landed = try TypLibrary.adopt(source: text, named: document.style.name)
            ctx.styles.rescanStyles()
            guard let style = StyleCatalog.libraryStyle(at: landed) else {
                message = t("copied to %@", Paths.display(landed))
                return .none
            }
            return .replace(StyleDetailScreen(style: style))
        } catch {
            message = error.localizedDescription
            return .none
        }
    }
}
