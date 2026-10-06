import Foundation

/// A headless entry point alongside the TUI, so builds can be scripted and the pipeline
/// can be exercised without a terminal.
///
/// Nothing here is translated: the command line is a scripting surface, and its flags and
/// messages are matched on by scripts.
enum CLI {
    /// Reads the flags every command shares, chooses the shape of the answer, and hands
    /// the rest to the command named first.
    static func run(_ arguments: [String]) async -> Int32 {
        let (rest, options) = CLIOptions.take(from: arguments)
        // Only shared flags: the usage, in the shape they asked for.
        let command = rest.first ?? "help"
        CLIOutput.begin(options, command: command)
        let console = ConsoleCodePage.utf8()
        defer { console.restore() }
        return CLIOutput.end(await dispatch(command, Array(rest.dropFirst())))
    }

    private static func dispatch(_ command: String, _ arguments: [String]) async -> Int32 {
        // `--help` on any command prints the usage; install has its own.
        if command != "install", arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
            return await dispatch("help", [])
        }
        switch command {
        case "-h", "--help", "help":
            CLILog.line(usage)
            CLIOutput.result(["usage": .string(usage)])
            return 0
        case "-v", "--version", "version":
            CLILog.line(Version.full)
            CLIOutput.result(["version": .string(Version.full)])
            return 0
        case "doctor", "styles":
            if let extra = arguments.first { return CLIOutput.refuse("kmap \(command) takes nothing, not \(extra)") }
            return command == "doctor" ? doctor() : listStyles()
        case "install": return await install(arguments)
        case "regions":
            // A region's name never starts with a dash: a flag here is a mistake, not a search.
            if let flag = arguments.first(where: { $0.hasPrefix("-") }) {
                return CLIOutput.refuse("kmap regions does not know \(flag)")
            }
            return await listRegions(query: arguments.joined(separator: " "))
        case "build": return await build(arguments)
        case "profiles": return profiles(arguments)
        case "hideable": return await hideable(arguments)
        case "verify": return verify(arguments)
        case "coverage": return coverage(arguments)
        case "typinfo": return typinfo(arguments)
        case "typdump": return typdump(arguments)
        case "typgen": return typgen(arguments)
        case "extract-typ": return extractTyp(arguments)
        case "img-elements": return imgElements(arguments)
        case "recover": return await recover(arguments)
        case "recover-check": return await recoverCheck(arguments)
        case "split": return split(arguments)
        case "contours": return contours(arguments)
        case "repair-roads": return repairRoads(arguments)
        case "burn-peaks": return burnPeaks(arguments)
        case "make-gpi": return makeGPI(arguments)
        case "osm-scan": return osmScan(arguments)
        // Ctrl+C stops its unzip, not kmap alone.
        case "fetch-dem": return await interruptible { await fetchDEM(arguments) }
        case "dem-cost": return await demCost(arguments)
        case "tif": return tif(arguments)
        case "tif2hgt": return tif2hgt(arguments)
        case "embed-assets": return embedAssets(arguments)
        default:
            let code = CLIOutput.failure("unknown command: \(command)", code: 2)
            CLILog.line("")
            CLILog.line(usage)
            return code
        }
    }
}
