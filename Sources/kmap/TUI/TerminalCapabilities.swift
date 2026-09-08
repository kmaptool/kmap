import Foundation

/// What the terminal on the other end can be asked to do.
enum TerminalCapabilities {

    /// Whether to emit 24-bit colour, so that a colour taken from a TYP is shown exactly
    /// rather than folded onto the 256-colour palette. On unless `KMAP_TRUECOLOR` is set
    /// to `0`, `no`, `off` or `false`, or `TERM` is `dumb`.
    static let trueColour: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if let flag = environment["KMAP_TRUECOLOR"] {
            return !["0", "no", "off", "false"].contains(flag.lowercased())
        }
        if let term = environment["TERM"], term == "dumb" { return false }
        return true
    }()
}
