import Foundation

/// `kmap install [tool]`: fetches what a build needs. Bare, everything missing that can be
/// installed automatically; the large optional packs only by name.
extension CLI {
    /// How often the installer's log is drained while a tool downloads.
    private static let installPollNanoseconds: UInt64 = 400_000_000
    /// Lines the installer's log keeps; the command line prints them as they come.
    private static let installLogLimit = 400

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

    static func install(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            CLILog.line(installHelp)
            return 0
        }
        // An unrecognised word refuses rather than falling back to installing everything.
        let downloading = arguments.contains("--download")
        if let flag = arguments.first(where: { $0.hasPrefix("-") && $0 != "--download" }) {
            return refuseInstall("kmap install does not know \(flag)")
        }
        let names = arguments.filter { !$0.hasPrefix("-") }
        if downloading, names != ["java"] {
            return refuseInstall(
                "--download is for java, which is the one thing kmap can fetch"
                    + " for itself as well as install"
            )
        }
        if names.count > 1 {
            return refuseInstall("kmap install takes one tool at a time, not \(names.count)")
        }
        let requested = names.first
        if let requested, !Toolchain.installableIDs.contains(requested) {
            return refuseInstall("nothing here is called \(requested)")
        }

        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let targets = installTargets(in: toolchain, requested: requested, downloading: downloading)
        guard !targets.isEmpty else {
            if let requested {
                CLILog.line("\(requested) is ready or cannot be installed automatically")
            } else {
                CLILog.line("nothing to install")
            }
            return 0
        }

        let log = Log(limit: installLogLimit, showing: CLIOutput.showing)
        let printer = Locked(LogPrinter())
        for tool in targets {
            CLILog.line("── installing \(tool.name)")
            let runner = ProcessRunner()
            let work = Task {
                try await toolchain.install(tool.id, log: log, runner: runner, downloading: downloading)
            }
            // Polled, so the slower installs report progress as they go.
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: installPollNanoseconds)
                    printer.withLock { $0.drain(log) }
                }
            }
            defer { ticker.cancel() }
            do {
                try await work.value
                printer.withLock { $0.drain(log) }
            } catch {
                printer.withLock { $0.drain(log) }
                return CLIOutput.failure("failed: \(error.localizedDescription)")
            }
        }
        CLILog.line("")
        return doctor()
    }

    /// What this run installs. A tool that works but cannot do everything is topped up
    /// only when named, so plain `kmap install` on a working machine installs nothing;
    /// optional packs likewise, since they run to hundreds of megabytes.
    private static func installTargets(
        in toolchain: Toolchain,
        requested: String?,
        downloading: Bool
    ) -> [ToolStatus] {
        let targets = toolchain.status()
            .filter { $0.installable }
            .filter { !$0.isFinished && (!$0.isReady || $0.id == requested) }
            .filter { requested == nil ? !$0.isOptional : $0.id == requested }
        // --download is asked for on purpose, so it applies to a Java that is already
        // there: the point is to have kmap's own rather than the machine's.
        if downloading, targets.isEmpty, let java = toolchain.status().first(where: { $0.id == "java" }) {
            return [java]
        }
        return targets
    }

    private static func refuseInstall(_ why: String) -> Int32 {
        CLIOutput.refuse(why + "\ntry: kmap install --help\n")
    }
}
