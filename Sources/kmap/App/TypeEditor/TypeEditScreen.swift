import Foundation

/// Edit one type: its colours, its drawing, and its names. Each change rewrites one line
/// of the file in place; there is no save step.
final class TypeEditScreen: Screen {
    var page: Page { Page(style.name, subject: TypeMeaning.hex(code), keys: keys) }

    private var keys: [Hint] {
        if picker != nil {
            return [
                Hint(key: "↑↓←→", label: t("move")),
                Hint(key: Glyph.enter, label: t("take it")),
                Hint(key: "esc", label: t("back to typing"))
            ]
        }
        if editing != nil {
            return [
                Hint(key: Glyph.enter, label: t("apply")),
                Hint(key: "^P", label: t("pick a colour")),
                Hint(key: "esc", label: t("cancel"))
            ]
        }
        var hints = [Hint(key: "↑↓", label: t("move"))]
        if case .colourPair = fields[safe: list.selected] {
            hints.append(Hint(key: "←→", label: t("day / night")))
        }
        hints.append(contentsOf: [
            Hint(key: Glyph.enter, label: t("change")),
            Hint(key: "esc", label: t("back"))
        ])
        return hints
    }

    enum Field {
        case picture
        /// The same block, in the pixel editor.
        case drawPicture
        /// A night slot is nil where the file says nothing: absent and same-as-day differ.
        case colourPair(role: String, day: TypSection.ColourSlot, night: TypSection.ColourSlot?)
        /// A point with no night picture, offering to start one from its day.
        case addNight
        case label(language: Int, name: String)
        case fontStyle
        case labelColour
    }

    /// What the compiler accepts for `FontStyle`; the empty entry leaves the size to the device.
    static let fontStyles = ["", "NoLabel", "SmallFont", "NormalFont", "LargeFont"]

    let style: MapStyle
    let kind: MapElementKind
    let code: Int
    let onEdited: () -> Void

    var document: StyleDocument
    var list = ListState()
    var editing: Field?
    /// Which half of a colour pair the cursor is on.
    var onNight = false
    var draft = ""
    var picker: ColourPicker?
    var message: String?
    var messageIsError = false

    init(
        style: MapStyle,
        kind: MapElementKind,
        code: Int,
        onEdited: @escaping () -> Void
    ) {
        self.style = style
        self.kind = kind
        self.code = code
        self.onEdited = onEdited
        self.document = StyleDocument.load(style)
    }

    var section: TypSection? { document.source?.section(kind, code) }

    var fields: [Field] {
        guard let section else { return [] }
        var out: [Field] = [.picture]
        // A solid type too: the drawing starts from the colour it already uses.
        if section.kind != .point || section.picture != nil { out.append(.drawPicture) }

        let slots = section.colourSlots
        for (index, day) in slots.day.enumerated() {
            out.append(
                .colourPair(
                    role: day.role,
                    day: day,
                    night: slots.night[safe: index]
                )
            )
        }
        if section.kind == .point, section.dayXpm != nil, section.nightXpm == nil {
            out.append(.addNight)
        }

        out.append(.label(language: TypLanguage.english, name: t("Name (English)")))
        out.append(.label(language: TypLanguage.russian, name: t("Name (Russian)")))
        out.append(.fontStyle)
        out.append(.labelColour)
        return out
    }
}
