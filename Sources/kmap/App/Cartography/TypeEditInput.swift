import Foundation

/// What the type editor does with the keys: field editing, the pickers, the saves.
extension TypeEditScreen {
    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if picker != nil { return handlePicker(key) }
        if editing != nil { return handleEditing(key) }

        let fields = self.fields
        switch key {
        case .up: list.move(-1, count: fields.count)
        case .down: list.move(1, count: fields.count)
        case .left: onNight = false
        case .right: onNight = true
        case .enter:
            guard let field = fields[safe: list.selected] else { return .none }
            switch field {
            case .picture: return borrowDrawing()
            case .drawPicture: return drawPicture()
            case .addNight: addNightPicture()
            case .fontStyle: cycleFontStyle()
            default: begin(field)
            }
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// Opens the picker for a drawing taken from another style, or from a file.
    private func borrowDrawing() -> Route {
        guard document.isEditable else {
            say(t("this style is read-only — take an editable copy first"), error: true)
            return .none
        }
        return .push(IconDonorScreen(kind: kind, target: section) { [weak self] picture in
            self?.apply(picture)
        })
    }

    /// Opens the picture in the pixel editor.
    private func drawPicture() -> Route {
        guard document.isEditable else {
            say(t("this style is read-only — take an editable copy first"), error: true)
            return .none
        }
        guard let editor = PixelEditorScreen(style: style, kind: kind, code: code,
                                             onSaved: { [weak self] in self?.reload() })
        else {
            say(t("there is no drawing here to edit — borrow one first"), error: true)
            return .none
        }
        return .push(editor)
    }

    /// Writes a borrowed drawing into this section, leaving everything around it alone.
    private func apply(_ picture: XpmBlock) {
        guard let source = document.source, let url = document.sourceURL else { return }
        do {
            let edited = try TypEdit.setPicture(in: source, kind: kind, code: code,
                                                to: picture)
            try TypLibrary.save(edited, to: url)
            reload()
            say(t("drawing replaced — %@, %@",
                  "\(picture.width)×\(picture.height)",
                  tn("%d colour(s)", picture.declaredColours)))
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Makes room for night colours on an element that has only day ones.
    private func addNightColours() {
        guard document.isEditable, let source = document.source,
              let url = document.sourceURL else {
            say(t("this style is read-only — take an editable copy first"), error: true)
            return
        }
        do {
            try TypLibrary.save(try TypEdit.addNightColours(in: source, kind: kind,
                                                            code: code), to: url)
            reload()
            say(t("night colours added, the same as day to start — now change them"))
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Gives a point a night picture drawn the same as its day one.
    private func addNightPicture() {
        guard document.isEditable, let source = document.source,
              let url = document.sourceURL else {
            say(t("this style is read-only — take an editable copy first"), error: true)
            return
        }
        do {
            try TypLibrary.save(try TypEdit.addNightPicture(in: source, code: code), to: url)
            reload()
            say(t("night version added, drawn the same — now change its colours"))
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Re-reads the file after a screen below has written to it.
    private func reload() {
        document = StyleDocument.load(style)
        onEdited()
    }

    private func begin(_ field: Field) {
        guard document.isEditable else {
            say(t("this style is read-only — take an editable copy first"), error: true)
            return
        }
        guard let section else { return }
        switch field {
        case .picture, .drawPicture, .addNight, .fontStyle:
            return
        case .colourPair(_, let day, let night):
            guard let slot = onNight ? night : day else {
                // Nothing to edit yet: the block grows from two colours to four, the new
                // pair copying the day one.
                addNightColours()
                return
            }
            draft = slot.colour ?? t("none")
        case .labelColour:
            draft = (onNight ? section.nightLabelColour : section.dayLabelColour) ?? t("none")
        case .label(let language, _):
            draft = section.label(language: language) ?? ""
        }
        editing = field
        message = nil
    }

    private func handleEditing(_ key: KeyEvent) -> Route {
        switch key {
        case .backspace: if !draft.isEmpty { draft.removeLast() }
        case .paste(let text): draft += text.replacingOccurrences(of: "\n", with: "")
        case .esc: editing = nil; draft = ""
        case .enter: apply()
        case .ctrl("p"):
            // Only a colour field has a picker.
            switch editing {
            case .colourPair?, .labelColour?:
                // The style's own colours are offered alongside the hue grid.
                picker = ColourPicker(start: draft, palette: styleColours())
            default: break
            }
        case .char(let c): draft.append(c)
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func handlePicker(_ key: KeyEvent) -> Route {
        guard var open = picker else { return .none }
        switch open.handle(key) {
        case .chose(let colour):
            draft = colour
            picker = nil
        case .cancelled:
            picker = nil
        case .none:
            picker = open
        }
        return .none
    }

    /// Rewrites the one line this field lives on, and reloads from disk.
    private func apply() {
        guard let field = editing, let source = document.source,
              let url = document.sourceURL else { return }
        let value = draft.trimmingCharacters(in: .whitespaces)

        do {
            let edited: String
            switch field {
            case .picture, .drawPicture, .addNight, .fontStyle:
                return
            case .labelColour:
                edited = try TypEdit.setLabelColour(
                    in: source, kind: kind, code: code, night: onNight,
                    to: meansNone(value) ? nil : value)
            case .colourPair(_, let day, let night):
                guard let slot = onNight ? night : day else { return }
                edited = try TypEdit.setColour(in: source, kind: kind, code: code,
                                               colourIndex: slot.index,
                                               to: meansNone(value) ? nil : value,
                                               tag: slot.tag)
            case .label(let language, _):
                edited = try TypEdit.setLabel(in: source, kind: kind, code: code,
                                              language: language, to: value)
            }
            try TypLibrary.save(edited, to: url)
            reload()
            say(t("saved"))
            editing = nil
            draft = ""
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Steps through the font sizes the compiler accepts, wrapping round. The first entry
    /// is the absence of the tag.
    private func cycleFontStyle() {
        guard document.isEditable, let source = document.source,
              let url = document.sourceURL, let section else {
            say(t("this style is read-only — take an editable copy first"), error: true)
            return
        }
        let styles = TypeEditScreen.fontStyles
        let current = styles.firstIndex(of: section.fontStyle ?? "") ?? 0
        let next = styles[(current + 1) % styles.count]
        do {
            try TypLibrary.save(try TypEdit.setFontStyle(in: source, kind: kind, code: code,
                                                         to: next.isEmpty ? nil : next),
                                to: url)
            reload()
            // The value is the compiler's own word and is not translated.
            say(next.isEmpty ? t("font style left to the device")
                             : t("font style: %@", next))
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Every colour this style already uses, most-used first, capped at 48.
    private func styleColours() -> [String] {
        guard let source = document.source else { return [] }
        var tally: [String: Int] = [:]
        for section in source.sections {
            for entry in (section.xpm?.palette ?? []) + (section.dayXpm?.palette ?? [])
                + (section.nightXpm?.palette ?? []) {
                guard let colour = entry.colour else { continue }
                tally[colour.uppercased(), default: 0] += 1
            }
            for colour in [section.dayLabelColour, section.nightLabelColour] {
                guard let colour else { continue }
                tally[colour.uppercased(), default: 0] += 1
            }
        }
        // Ties broken by the colour itself, so the row does not shuffle between frames.
        return tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(48).map(\.key)
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }
}
