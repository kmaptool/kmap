import Foundation

/// Adding a section for a code the TYP does not style, and deleting one after asking.
extension TypeBrowserScreen {
    private static let readOnlyNote = "this style is read-only — take an editable copy first"

    /// A TYP covers only what its author wrote; a code with no section is drawn by the device.
    func addSection(_ ctx: AppContext) -> Route {
        guard let row = selectedRow else { return .none }
        guard !row.isStyled else {
            notice.say(t("%@ already has a section — press ⏎ to change it", row.hex), error: true)
            return .none
        }
        guard document.isEditable, let source = document.source, let url = document.sourceURL else {
            notice.say(t(Self.readOnlyNote), error: true)
            return .none
        }
        do {
            let edited = try TypEdit.addSection(in: source, kind: kind, code: row.code, label: row.tags.first)
            try TypLibrary.save(edited, to: url)
            reload()
            notice.say(t("added a section for %@ — magenta until you draw it", row.hex))
            return .push(editor(for: row))
        } catch {
            notice.say(error.localizedDescription, error: true)
            return .none
        }
    }

    /// The drawing and the names cannot be recovered once the file is rewritten, so the
    /// cursor starts on cancel.
    func askToRemoveSection() {
        guard let row = selectedRow else { return }
        guard let section = row.section else {
            notice.say(t("this TYP has no section for %@ — press a to add one", row.hex), error: true)
            return
        }
        guard document.isEditable else {
            notice.say(t(Self.readOnlyNote), error: true)
            return
        }
        var body = [
            t(
                "The section for %@ will be deleted: its drawing, its colours and"
                    + " its names. The device will then draw this type its own way.",
                row.hex
            )
        ]
        if kind == .polygon {
            body.append(t("Its entry in the draw order will be deleted too."))
        }
        body.append(
            t(
                "The file is rewritten at once. A new section can be created with a, but the current colours and drawing will be lost."
            )
        )
        var detail = [(t("type"), row.hex)]
        if let name = section.label(language: russian ? TypLanguage.russian : TypLanguage.english)
            ?? section.englishLabel
        {
            detail.append((t("name"), name))
        }
        if let tag = row.tags.first { detail.append((t("drawn for"), tag)) }
        asking = Question(
            dialog: Dialog(
                title: t("Delete the section"),
                body: body,
                detail: detail,
                confirm: t("delete"),
                cancel: t("cancel")
            ),
            subject: row
        )
    }

    func removeSection(_ row: StyleTypeRow) {
        guard let source = document.source, let url = document.sourceURL else { return }
        do {
            try TypLibrary.save(try TypEdit.removeSection(in: source, kind: kind, code: row.code), to: url)
            reload()
            notice.say(t("section for %@ deleted — the device will draw this type its own way", row.hex))
        } catch {
            notice.say(error.localizedDescription, error: true)
        }
    }
}
