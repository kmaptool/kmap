import Foundation

extension TypEdit {
    enum EditError: LocalizedError {
        case noSuchSection(MapElementKind, Int)
        case noPicture(Int)
        case noSuchColour(Int, Int)
        case notAColour(String)
        case noDrawOrder
        case notALevel(Int)
        case noNightForm(Int)
        /// What mkgmap refuses in a line's or a polygon's colours: see `refusal(ofSimple:)`.
        case tooManyColours
        case onlyColourClear
        case bothClear(night: Bool)

        var errorDescription: String? {
            switch self {
            case .noDrawOrder:
                return t("this TYP declares no draw order")
            case .tooManyColours:
                return t("a line or polygon has at most 4 colours: an ink and a background, by day and by night")
            case .onlyColourClear:
                return t("the only colour of a line or polygon cannot be clear")
            case .bothClear(let night):
                return night
                    ? t("the night ink and background cannot both be clear")
                    : t("the day ink and background cannot both be clear")
            case .notALevel(let level):
                return t("%d is not a draw-order level — the lowest is 1", level)
            case .noNightForm(let code):
                return t(
                    "%@ has no night form: a pattern needs an ink and a background"
                        + " before night can be added — give it a background first",
                    TypeMeaning.hex(code)
                )
            case .noSuchSection(let kind, let code):
                return t(
                    "this TYP has no %1$@ section for %2$@",
                    kind.rawValue,
                    TypeMeaning.hex(code)
                )
            case .noPicture(let code):
                return t("%@ has no Xpm block to change", TypeMeaning.hex(code))
            case .noSuchColour(let code, let index):
                return t("%1$@ has no colour %2$d", TypeMeaning.hex(code), index + 1)
            case .notAColour(let text):
                return t("%@ is not a #RRGGBB colour", text)
            }
        }
    }

    enum AddError: LocalizedError {
        case alreadyThere(MapElementKind, Int)

        var errorDescription: String? {
            switch self {
            case .alreadyThere(let kind, let code):
                return t(
                    "this TYP already has a %1$@ section for %2$@",
                    kind.rawValue,
                    TypeMeaning.hex(code)
                )
            }
        }
    }
}
