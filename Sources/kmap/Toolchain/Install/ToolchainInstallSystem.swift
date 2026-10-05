import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a module of its own outside Apple's platforms.
import FoundationNetworking
#endif

/// What the machine's own package manager and pip install for kmap.
extension Toolchain {
    /// Asks the machine's own package manager for something kmap does not ship.
    ///
    /// Refuses before running anything where root is needed and sudo would ask for a
    /// password: children get /dev/null for stdin, so the prompt would hang unseen.
    func installSystemPackage(
        _ what: PackageManager.Need,
        log: Log,
        runner: ProcessRunner,
        progress: InstallProgress? = nil
    ) async throws {
        guard let manager = PackageManager.detect() else {
            throw InstallError.unsupported(
                t(
                    "no package manager kmap knows was found — install %@ by hand",
                    what.spokenName
                )
            )
        }
        let privilege = Privilege.forInstalling(with: manager)
        guard let command = manager.command(for: what, privilege: privilege) else {
            throw InstallError.unsupported(
                t(
                    "%1$@ has no name for %2$@ that kmap knows",
                    manager.spokenName,
                    what.spokenName
                )
            )
        }
        guard command.runnable else {
            // A root install where sudo wants a password: report the exact command instead.
            throw InstallError.unsupported(
                t(
                    "this needs a root password, which kmap cannot ask for from here. Run:  %@",
                    manager.spokenCommand(for: what, privilege: privilege) ?? ""
                )
            )
        }

        progress?.step(t("installing %1$@ with %2$@", what.spokenName, manager.spokenName))
        log.step(t("installing %1$@ with %2$@", what.spokenName, manager.spokenName))
        guard let executable = Platform.which(command.executable) else {
            throw InstallError.unsupported(
                t(
                    "%@ is not where it said it was",
                    command.executable
                )
            )
        }
        if let refresh = manager.refreshCommand(privilege: privilege),
            let refresher = Platform.which(refresh.executable)
        {
            // A list that will not refresh, say for 1 dead source, still may install.
            do {
                try await runner.run(refresher, refresh.arguments, environment: ["DEBIAN_FRONTEND": "noninteractive"]) {
                    line in log.output(line)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.warn("could not refresh the package lists: \(ErrorWords.of(error))")
            }
        }
        // apt refuses to run without this when there is no terminal to ask questions on.
        try await runner.run(
            executable,
            command.arguments,
            environment: ["DEBIAN_FRONTEND": "noninteractive"]
        ) { line in
            log.output(line)
        }
        invalidate()
        log.ok(t("%@ installed", what.spokenName))
    }

    /// The pyhgtmap release kmap installs: a newer one is taken only by a newer kmap.
    static let pyhgtmapVersion = "4.1"

    func installPyhgtmap(
        log: Log,
        runner: ProcessRunner,
        progress: InstallProgress? = nil
    ) async throws {
        // pyhgtmap lives in a virtualenv, which needs a python3 to build it from.
        if findPython3() == nil, Toolchain.canInstall(.python) {
            try await installSystemPackage(
                .python,
                log: log,
                runner: runner,
                progress: progress
            )
        }
        guard let python = findPython3() else {
            throw InstallError.unsupported(
                "python3 not found — install with: "
                    + Platform.installHint(.python)
            )
        }
        Paths.ensure(Paths.tools)

        if !FileTools.exists(ToolLocations.inVirtualEnvironment("pip", of: Paths.venv)) {
            progress?.step(t("creating a private Python environment"))
            log.step("creating a private Python environment")
            try await runner.run(python, ["-m", "venv", Paths.venv.path]) { log.append($0) }
        }

        progress?.step(t("installing pyhgtmap"))
        log.step("installing pyhgtmap (this pulls in a few geo libraries — give it a minute)")
        let pip = ToolLocations.inVirtualEnvironment("pip", of: Paths.venv).nativePath
        try await runner.run(
            pip,
            [
                "install", "--upgrade", "--disable-pip-version-check",
                "pyhgtmap==\(Toolchain.pyhgtmapVersion)"
            ]
        ) { line in
            // pip is chatty; keep the useful lines.
            if line.hasPrefix("Collecting") || line.hasPrefix("Successfully")
                || line.hasPrefix("Installing") || line.contains("error")
            {
                log.output(line)
            }
        }

        // The file itself, not `findPyhgtmap()`, whose answer was cached before this
        // install ran.
        guard FileTools.isExecutable(pyhgtmapBinary.nativePath) else {
            throw InstallError.failed("pyhgtmap did not appear in \(Paths.display(Paths.venv))")
        }

        log.ok("pyhgtmap ready")
    }
}
