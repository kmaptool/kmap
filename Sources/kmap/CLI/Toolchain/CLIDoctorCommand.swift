import Foundation

/// `kmap doctor`: what is installed, what a build cannot run without, and where the
/// folders are. Exits non-zero while a required tool is missing, so a script can use it
/// as a gate.
extension CLI {
    static func doctor() -> Int32 {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let tools = toolchain.status()
        var allReady = true
        // As wide as the longest name: the names are translated, so no fixed width fits.
        let column = tools.map(\.name.count).max() ?? 0
        for tool in tools {
            let mark = tool.isReady ? "ok  " : "MISSING"
            let name = tool.name + String(repeating: " ", count: max(0, column - tool.name.count))
            // A ready tool with a note is one that cannot do everything.
            let said = [tool.version, tool.note].compactMap { $0 }.joined(separator: "  ")
            CLILog.line("\(mark)  \(name)  \(said)")
            if let path = tool.path { CLILog.line("        \(path)") }
            // An optional extra is information, not a failure: `ready` answers the same
            // question `canBuild` asks.
            if !tool.isReady && !tool.isOptional { allReady = false }
        }
        CLILog.line("")
        CLILog.line("output  \(Paths.display(settings.settings.outputURL))")
        CLILog.line("work    \(Paths.display(settings.settings.workURL))")
        CLILog.line("cache   \(Paths.display(Paths.pbfCache))")
        CLIOutput.result([
            "ready": .bool(allReady),
            "tools": .array(
                tools.map { tool in
                    [
                        "id": .string(tool.id), "name": .string(tool.name),
                        "ready": .bool(tool.isReady), "installable": .bool(tool.installable),
                        "optional": .bool(tool.isOptional),
                        "version": .of(tool.version), "note": .of(tool.note),
                        "path": .of(tool.path)
                    ]
                }
            ),
            "folders": [
                "output": .string(settings.settings.outputURL.path),
                "work": .string(settings.settings.workURL.path),
                "cache": .string(Paths.pbfCache.path)
            ]
        ])
        return allReady ? 0 : 1
    }
}
