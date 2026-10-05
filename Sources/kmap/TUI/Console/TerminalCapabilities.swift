import Foundation

/// What the terminal on the other end can be asked to do.
enum TerminalCapabilities {
    /// Whether to emit 24-bit colour, so that a colour taken from a TYP is shown exactly
    /// rather than folded onto the 256-colour palette. `KMAP_TRUECOLOR` decides where set;
    /// otherwise on, except on the terminals known to show it wrong.
    static let trueColour: Bool = trueColour(
        environment: ProcessInfo.processInfo.environment,
        macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )

    static func trueColour(environment: [String: String], macOSMajor: Int) -> Bool {
        if let flag = environment["KMAP_TRUECOLOR"] {
            return !["0", "no", "off", "false"].contains(flag.lowercased())
        }
        // Said outright by the terminal.
        if let colour = environment["COLORTERM"]?.lowercased(), colour == "truecolor" || colour == "24bit" {
            return true
        }
        let term = environment["TERM"] ?? ""
        // The Linux console and GNU screen draw a 24-bit colour as some other colour.
        if term == "dumb" || term == "linux" || term.hasPrefix("screen") { return false }
        #if os(macOS)
        // Terminal.app learnt 24-bit colour in macOS 26.
        if environment["TERM_PROGRAM"] == "Apple_Terminal" { return macOSMajor >= 26 }
        #endif
        return true
    }
}
