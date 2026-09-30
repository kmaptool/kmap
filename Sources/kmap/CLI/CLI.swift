import Foundation

#if os(Windows)
import WinSDK
#endif

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
        guard let command = rest.first else {
            CLILog.line(usage)
            return 0
        }
        CLIOutput.begin(options, command: command)
        let console = ConsoleCodePage.utf8()
        defer { console.restore() }
        return CLIOutput.end(await dispatch(command, Array(rest.dropFirst())))
    }

    /// The console's code page for the run: UTF-8, as the TUI sets it, or every dash and
    /// dot in the output is mojibake on a console at the OEM page. Put back on exit.
    struct ConsoleCodePage {
        #if os(Windows)
        private let input: UINT, output: UINT
        /// The pages found at the start, for an exit that does not unwind to the defer:
        /// a second Ctrl+C leaves through `exit`.
        nonisolated(unsafe) private static var found: ConsoleCodePage?

        static func utf8() -> ConsoleCodePage {
            let saved = ConsoleCodePage(input: GetConsoleCP(), output: GetConsoleOutputCP())
            found = saved
            SetConsoleCP(UINT(CP_UTF8))
            SetConsoleOutputCP(UINT(CP_UTF8))
            return saved
        }

        func restore() {
            SetConsoleCP(input)
            SetConsoleOutputCP(output)
        }

        static func restoreFound() { found?.restore() }
        #else
        static func utf8() -> ConsoleCodePage { ConsoleCodePage() }
        func restore() {}
        static func restoreFound() {}
        #endif
    }

    private static func dispatch(_ command: String, _ arguments: [String]) async -> Int32 {
        switch command {
        case "-h", "--help", "help":
            CLILog.line(usage)
            CLIOutput.result(["usage": .string(usage)])
            return 0
        case "-v", "--version", "version":
            CLILog.line(Version.full)
            CLIOutput.result(["version": .string(Version.full)])
            return 0
        case "doctor": return doctor()
        case "install": return await install(arguments)
        case "regions": return await listRegions(query: arguments.joined(separator: " "))
        case "build": return await build(arguments)
        case "styles": return listStyles()
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
        case "fetch-dem": return await fetchDEM(arguments)
        case "dem-cost": return await demCost(arguments)
        case "tif": return tif(arguments)
        case "tif2hgt": return tif2hgt(arguments)
        case "embed-assets": return embedAssets(arguments)
        default:
            let code = CLIOutput.failure("unknown command: \(command)\n", code: 2)
            CLILog.line(usage)
            return code
        }
    }
}
