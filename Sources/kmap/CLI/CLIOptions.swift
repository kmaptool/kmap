import Foundation

/// The flags every command understands, read before the command is chosen.
///
/// They are taken out of the arguments rather than left in them: a command that treats
/// what is left as a search term -- `kmap regions`, `kmap hideable` -- would otherwise
/// search for the flag.
struct CLIOptions {
    /// Write one JSON object per line to standard output instead of text.
    var json = false
    /// Show the detail a run normally keeps to its log file.
    var verbose = false

    /// The lowest severity the command line shows.
    var showing: LogSeverity { verbose ? .debug : .info }

    static let names: Set<String> = ["json", "verbose"]

    /// Reads them out of `arguments` and returns what is left, in order.
    static func take(from arguments: [String]) -> (rest: [String], options: CLIOptions) {
        var options = CLIOptions()
        var rest: [String] = []
        for argument in arguments {
            switch argument {
            case "--json": options.json = true
            case "--verbose": options.verbose = true
            default: rest.append(argument)
            }
        }
        return (rest, options)
    }
}
