import Foundation

/// The lettered commands: new, import, rename, duplicate, restore, delete, make default.
extension StyleListScreen {
    func command(_ letter: Character?, visible: [MapStyle], ctx: AppContext) -> Route {
        switch letter {
        case "/":
            search.open = true
            notice.clear()
        case "n":
            return newStyle(ctx)
        case "i":
            return .push(ImportTypScreen(onImported: { [weak self] in self?.scanned = false }))
        case "r":
            guard let style = visible[safe: list.selected] else { return .none }
            beginRename(style)
        case "d":
            guard let style = visible[safe: list.selected] else { return .none }
            guard libraryFile(of: style) != nil else {
                notice.say(t("only a style in your library can be deleted"), error: true)
                return .none
            }
            confirming = style
        case "c":
            guard let style = visible[safe: list.selected] else { return .none }
            copyStyle(style, ctx)
        case "o":
            guard let style = visible[safe: list.selected] else { return .none }
            beginRestore(style)
        case "m":
            guard let style = visible[safe: list.selected] else { return .none }
            ctx.settings.update { $0.defaultStyleID = style.id }
            notice.say(t("%@ is now the default", style.name))
        default: break
        }
        return .none
    }

    private func beginRename(_ style: MapStyle) {
        guard libraryFile(of: style) != nil else {
            notice.say(t("only a style in your library can be renamed"), error: true)
            return
        }
        renaming = true
        name.text = style.name
        notice.clear()
    }

    /// A built-in is copied from its source; the copy lands in the library, editable.
    private func copyStyle(_ style: MapStyle, _ ctx: AppContext) {
        do {
            let copy: URL
            if let shipped = StyleCatalog.shippedPalette(id: style.id) {
                copy = try TypLibrary.adopt(source: try StyleCatalog.shippedTypText(of: shipped), named: style.name)
            } else if let url = libraryFile(of: style) {
                copy = try TypLibrary.duplicate(url)
            } else {
                notice.say(t("only a style in your library can be copied"), error: true)
                return
            }
            reload(ctx, select: copy)
            notice.say(t("copied to %@", copy.deletingPathExtension().lastPathComponent))
        } catch {
            notice.say(error.localizedDescription, error: true)
        }
    }

    /// Restoring throws real work away, so it asks first.
    private func beginRestore(_ style: MapStyle) {
        guard let url = libraryFile(of: style) else {
            notice.say(t("only a style in your library can be restored"), error: true)
            return
        }
        guard TypLibrary.original(of: url) != nil else {
            notice.say(t("this style has no original kept — nothing was imported to go back to"), error: true)
            return
        }
        asking = Question(
            dialog: Dialog(
                title: t("Overwrite"),
                body: [
                    t(
                        "%@ will be rewritten from the binary kept when it was"
                            + " imported. Everything changed in it since is lost.",
                        style.name
                    ),
                    t("The copy kept at import is not touched, so this can be done again.")
                ],
                detail: [(t("style"), style.name)],
                confirm: t("restore"),
                cancel: t("cancel"),
                tone: .plain
            ),
            subject: style
        )
    }

    /// Rewrites the working copy from the binary kept at import.
    func restore(_ style: MapStyle, _ ctx: AppContext) {
        guard let url = libraryFile(of: style) else { return }
        do {
            try TypLibrary.restore(url)
            reload(ctx, select: url)
            notice.say(t("%@ is back as it was imported", style.name))
        } catch {
            notice.say(error.localizedDescription, error: true)
        }
    }

    func handleRename(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch name.handle(key) {
        case .typing: break
        case .quit: return .quit
        case .cancelled: renaming = false
        case .accepted(let wanted):
            renaming = false
            guard let style = filtered[safe: list.selected], let url = libraryFile(of: style) else { return .none }
            let wasDefault = ctx.settings.settings.defaultStyleID == style.id
            do {
                let moved = try TypLibrary.rename(url, to: wanted)
                reload(ctx, select: moved)
                // The id follows the name, so the default setting follows the id.
                if wasDefault, let now = styles.first(where: { $0.typURL?.sameFile(as: moved) == true }) {
                    ctx.settings.update { $0.defaultStyleID = now.id }
                }
                notice.say(t("renamed to %@", moved.deletingPathExtension().lastPathComponent))
            } catch {
                notice.say(error.localizedDescription, error: true)
            }
        }
        return .none
    }

    func handleConfirm(_ key: KeyEvent, style: MapStyle, ctx: AppContext) -> Route {
        switch YesNo.answer(key) {
        case .yes:
            confirming = nil
            delete(style, ctx)
        case .no: confirming = nil
        case .quit: return .quit
        case nil: break
        }
        return .none
    }

    /// Deleting the default moves the setting to another style and says which.
    private func delete(_ style: MapStyle, _ ctx: AppContext) {
        guard let url = libraryFile(of: style) else { return }
        let wasDefault = ctx.settings.settings.defaultStyleID == style.id
        do {
            try TypLibrary.delete(url)
            reload(ctx)
            guard wasDefault else {
                notice.say(t("deleted %@", style.name))
                return
            }
            let replacement =
                styles.first { libraryFile(of: $0) != nil }
                ?? styles.first { $0.id == "plain" }
                ?? styles.first
            if let replacement {
                ctx.settings.update { $0.defaultStyleID = replacement.id }
                notice.say(t("deleted %@ — it was the default, which is now %@", style.name, replacement.name))
            } else {
                notice.say(t("deleted %@ — nothing is left to be the default", style.name))
            }
        } catch {
            notice.say(error.localizedDescription, error: true)
        }
    }

    private func newStyle(_ ctx: AppContext) -> Route {
        do {
            // The name becomes a file name, so it is not translated.
            let url = try TypLibrary.create(named: "new style")
            reload(ctx, select: url)
            // By resolved path: a library behind a symlink yields two spellings.
            guard let style = styles.first(where: { $0.typURL?.sameFile(as: url) == true }) else { return .none }
            return .push(StyleDetailScreen(style: style))
        } catch {
            notice.say(error.localizedDescription, error: true)
            return .none
        }
    }
}
