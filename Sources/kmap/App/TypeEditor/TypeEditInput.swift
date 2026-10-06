import Foundation

/// What the type editor does with the keys: field editing, the pickers, the saves.
extension TypeEditScreen {
    private static let readOnlyNote = "this style is read-only — take an editable copy first"
    private static let mostStyleColours = 48

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if let (answer, picture) = replacing.take(key) {
            if answer == .confirmed { apply(picture) }
            return .none
        }
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

    private func borrowDrawing() -> Route {
        guard document.isEditable else {
            say(t(Self.readOnlyNote), error: true)
            return .none
        }
        return .push(
            IconDonorScreen(kind: kind, target: section) { [weak self] picture in
                guard let self else { return }
                guard self.section?.picture != nil else { return self.apply(picture) }
                self.replacing = Question(
                    dialog: Dialog(
                        title: t("Replace the drawing"),
                        body: [
                            t(
                                "%@ keeps no copy of the drawing it has now: once replaced, it is gone.",
                                TypeMeaning.hex(self.code)
                            )
                        ],
                        confirm: t("replace"),
                        cancel: t("cancel")
                    ),
                    subject: picture
                )
            }
        )
    }

    private func drawPicture() -> Route {
        guard document.isEditable else {
            say(t(Self.readOnlyNote), error: true)
            return .none
        }
        guard
            let editor = PixelEditorScreen(
                style: style,
                kind: kind,
                code: code,
                onSaved: { [weak self] in self?.reload() }
            )
        else {
            say(t("there is no drawing here to edit — borrow one first"), error: true)
            return .none
        }
        return .push(editor)
    }

    private func apply(_ picture: XpmBlock) {
        guard let source = document.source, let url = document.sourceURL else { return }
        do {
            var edited = try TypEdit.setPicture(
                in: source,
                kind: kind,
                code: code,
                to: picture
            )
            // A point's old night picture would show the old icon after dark: the new
            // drawing takes its place, in the day's colours until changed.
            let night = kind == .point && source.section(.point, code)?.nightXpm != nil
            if night {
                edited = try TypEdit.setPicture(
                    in: TypSource.parse(edited),
                    kind: kind,
                    code: code,
                    to: picture,
                    tag: "NightXpm"
                )
            }
            try TypLibrary.save(edited, to: url)
            reload()
            say(
                t(
                    "drawing replaced — %@, %@",
                    "\(picture.width)×\(picture.height)",
                    tn("%d colour(s)", picture.declaredColours)
                ) + (night ? " · " + t("the night picture too, in these colours") : "")
            )
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    private func addNightColours() {
        guard document.isEditable, let source = document.source, let url = document.sourceURL else {
            say(t(Self.readOnlyNote), error: true)
            return
        }
        do {
            try TypLibrary.save(try TypEdit.addNightColours(in: source, kind: kind, code: code), to: url)
            reload()
            say(t("night colours added, the same as day to start — now change them"))
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    private func addNightPicture() {
        guard document.isEditable, let source = document.source, let url = document.sourceURL else {
            say(t(Self.readOnlyNote), error: true)
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

    private func reload() {
        document = StyleDocument.load(style)
        onEdited()
    }

    private func begin(_ field: Field) {
        guard document.isEditable else {
            say(t(Self.readOnlyNote), error: true)
            return
        }
        guard let section else { return }
        switch field {
        case .picture, .drawPicture, .addNight, .fontStyle:
            return
        case .colourPair(_, let day, let night):
            guard let slot = onNight ? night : day else {
                // No night pair yet: the block grows from two colours to four.
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
            switch editing {
            case .colourPair?, .labelColour?:
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

    /// Rewrites the one line this field lives on.
    private func apply() {
        guard let field = editing, let source = document.source,
            let url = document.sourceURL
        else { return }
        let value = draft.trimmingCharacters(in: .whitespaces)

        do {
            let edited: String
            switch field {
            case .picture, .drawPicture, .addNight, .fontStyle:
                return
            case .labelColour:
                edited = try TypEdit.setLabelColour(
                    in: source,
                    kind: kind,
                    code: code,
                    night: onNight,
                    to: meansNone(value) ? nil : value
                )
            case .colourPair(_, let day, let night):
                guard let slot = onNight ? night : day else { return }
                edited = try TypEdit.setColour(
                    in: source,
                    kind: kind,
                    code: code,
                    colourIndex: slot.index,
                    to: meansNone(value) ? nil : value,
                    tag: slot.tag
                )
            case .label(let language, _):
                edited = try TypEdit.setLabel(
                    in: source,
                    kind: kind,
                    code: code,
                    language: language,
                    to: value
                )
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

    /// Steps through the font sizes the compiler accepts, wrapping round.
    private func cycleFontStyle() {
        guard document.isEditable, let source = document.source, let url = document.sourceURL, let section else {
            say(t(Self.readOnlyNote), error: true)
            return
        }
        let styles = TypeEditScreen.fontStyles
        let current = styles.firstIndex(of: section.fontStyle ?? "") ?? 0
        let next = styles[(current + 1) % styles.count]
        do {
            try TypLibrary.save(
                try TypEdit.setFontStyle(
                    in: source,
                    kind: kind,
                    code: code,
                    to: next.isEmpty ? nil : next
                ),
                to: url
            )
            reload()
            say(next.isEmpty ? t("font style left to the device") : t("font style: %@", next))
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Every colour this style already uses, most-used first.
    private func styleColours() -> [String] {
        guard let source = document.source else { return [] }
        var tally: [String: Int] = [:]
        for section in source.sections {
            for entry in (section.xpm?.palette ?? []) + (section.dayXpm?.palette ?? [])
                + (section.nightXpm?.palette ?? [])
            {
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
            .prefix(Self.mostStyleColours).map(\.key)
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }
}
