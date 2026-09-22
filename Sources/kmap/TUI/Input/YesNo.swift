import Foundation

/// A yes/no question. `y` on any layout is yes; `n` and Esc are no; any other key
/// returns nil and leaves the question open.
enum YesNo {
    enum Answer { case yes, no, quit }

    static func answer(_ key: KeyEvent) -> Answer? {
        switch key {
        case .char(let c) where Keys.latin(c) == "y": return .yes
        case .char(let c) where Keys.latin(c) == "n": return .no
        case .esc: return .no
        case .ctrl("c"): return .quit
        default: return nil
        }
    }
}
