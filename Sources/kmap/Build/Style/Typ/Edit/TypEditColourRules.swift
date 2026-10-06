import Foundation

extension TypEdit {
    /// What mkgmap's compiler refuses in a line's or a polygon's palette, nil for clear,
    /// in its own order: up to 4 colours, and at most 1 clear in each day or night pair,
    /// which is never a pair's only colour.
    static func refusal(ofSimple colours: [String?]) -> EditError? {
        var colours = colours
        guard colours.count <= 4 else { return .tooManyColours }
        guard !colours.isEmpty else { return nil }
        if colours[0] == nil {
            guard colours.count >= 2 else { return .onlyColourClear }
            colours.swapAt(0, 1)
        }
        if colours.count > 2, colours[2] == nil {
            guard colours.count >= 4 else { return .onlyColourClear }
            colours.swapAt(2, 3)
        }
        if colours.count > 1, colours[0] == nil { return .bothClear(night: false) }
        if colours.count > 3, colours[2] == nil { return .bothClear(night: true) }
        return nil
    }
}
