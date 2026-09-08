import Foundation

/// The toolchain commands: `doctor` reports what is installed and what a build cannot run
/// without, `install` fetches it. Both write English to stdout, the command line being a
/// scripting surface.
extension CLI {
    /// What `kmap install` can be asked for, and what it does without being asked.
    private static var installHelp: String {
        """
        kmap install [tool]           install missing tools

          With no tool, everything a build needs that is missing and can be installed
          automatically. The large optional packs are left alone — one of them is a
          344 MB download and one is 2.5 GB — so they are only fetched by name.

        tools
        \(Toolchain.installableIDs.map { "  " + $0 }.joined(separator: "\n"))

          java, python and unzip are packages rather than files, so they come from this
          machine's own package manager. Where that needs a root password kmap cannot
          type, it prints the command for you instead — and for java, where there is no
          manager to ask at all, kmap downloads a JDK into ~/.kmap/tools instead.

        options
          --download                  for java: fetch that JDK even where the package
                                      manager could install one, leaving the rest of
                                      the machine untouched
        """
    }

    static func doctor() -> Int32 {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let tools = toolchain.status()
        var allReady = true
        // Wide enough for the longest name there is, rather than a fixed twelve.
        // `padding(toLength:)` truncates as readily as it pads, so the fixed width cut
        // "coastline data" to "coastline da" — and the names are translated, so no
        // constant could have been right in both languages anyway.
        let column = tools.map(\.name.count).max() ?? 0
        for tool in tools {
            let mark = tool.isReady ? "ok  " : "MISSING"
            let name = tool.name + String(repeating: " ", count: max(0, column - tool.name.count))
            // Both where there are both: a ready tool with a note is one that cannot do
            // everything, and the version alone would not say so.
            let said = [tool.version, tool.note].compactMap { $0 }.joined(separator: "  ")
            CLILog.line("\(mark)  \(name)  \(said)")
            if let path = tool.path { CLILog.line("        \(path)") }
            // An optional extra — coastline pack, pyhgtmap — is information, not a
            // failure: `ready` answers "can a build run", the same question `canBuild`
            // asks, so scripting `kmap doctor` as a gate works on a fresh machine.
            if !tool.isReady && !tool.isOptional { allReady = false }
        }
        CLILog.line("")
        CLILog.line("output  \(Paths.display(settings.settings.outputURL))")
        CLILog.line("work    \(Paths.display(settings.settings.workURL))")
        CLILog.line("cache   \(Paths.display(Paths.pbfCache))")
        CLIOutput.result([
            "ready": .bool(allReady),
            "tools": .array(tools.map { tool in
                ["id": .string(tool.id), "name": .string(tool.name),
                 "ready": .bool(tool.isReady), "installable": .bool(tool.installable),
                 "optional": .bool(tool.isOptional),
                 "version": .of(tool.version), "note": .of(tool.note),
                 "path": .of(tool.path)]
            }),
            "folders": ["output": .string(settings.settings.outputURL.path),
                        "work": .string(settings.settings.workURL.path),
                        "cache": .string(Paths.pbfCache.path)],
        ])
        return allReady ? 0 : 1
    }

    /// Says no, on the error stream, with the exit code a script can act on.
    static func refuse(_ what: String) -> Int32 {
        CLIOutput.failure(what + "\ntry: kmap install --help\n", code: 2)
    }

    static func install(_ arguments: [String]) async -> Int32 {
        // An unrecognised word refuses rather than falling back to the default, which here
        // is to install everything missing.
        if arguments.contains("--help") || arguments.contains("-h") {
            CLILog.line(installHelp)
            return 0
        }
        let downloading = arguments.contains("--download")
        if let flag = arguments.first(where: {
            $0.hasPrefix("-") && $0 != "--download"
        }) {
            return refuse("kmap install does not know \(flag)")
        }
        let names = arguments.filter { !$0.hasPrefix("-") }
        if downloading, names != ["java"] {
            return refuse("--download is for java, which is the one thing kmap can fetch"
                          + " for itself as well as install")
        }
        if names.count > 1 {
            return refuse("kmap install takes one tool at a time, not \(names.count)")
        }
        let requested = names.first
        if let requested, !Toolchain.installableIDs.contains(requested) {
            return refuse("nothing here is called \(requested)")
        }

        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)

        // Optional packs are installed only when named: they run to hundreds of megabytes.
        var targets = toolchain.status()
            .filter { $0.installable }
            // A tool that works but cannot do everything is topped up only when it is
            // named: plain `kmap install` on a working machine installs nothing.
            .filter { !$0.isFinished && (!$0.isReady ? true : $0.id == requested) }
            .filter { requested == nil ? !$0.isOptional : $0.id == requested }
        // --download is asked for on purpose, so it applies to a Java that is already
        // there: the point is to have kmap's own rather than the machine's.
        if downloading, targets.isEmpty,
           let java = toolchain.status().first(where: { $0.id == "java" }) {
            targets = [java]
        }

        guard !targets.isEmpty else {
            if let requested {
                CLILog.line("\(requested) is ready or cannot be installed automatically")
            } else {
                CLILog.line("nothing to install")
            }
            return 0
        }

        let log = Log(limit: 400, showing: CLIOutput.showing)
        var printed = 0

        // Drain whatever the installer has logged so far.
        func drain() {
            let lines = log.snapshot()
            guard lines.count > printed else { return }
            for line in lines[printed...] {
                CLILog.line(prefix(line) + line.text)
                CLIOutput.log(line)
            }
            printed = lines.count
        }

        for tool in targets {
            CLILog.line("── installing \(tool.name)")
            let runner = ProcessRunner()
            let work = Task {
                try await toolchain.install(tool.id, log: log, runner: runner,
                                            downloading: downloading)
            }

            // Polled, so the slower installs report progress as they go.
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    drain()
                }
            }
            defer { ticker.cancel() }

            do {
                try await work.value
                drain()
            } catch {
                drain()
                return CLIOutput.failure("failed: \(error.localizedDescription)")
            }
        }
        CLILog.line("")
        return doctor()
    }
}
