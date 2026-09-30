import Foundation

/// Starting and stopping installs.
extension ToolchainScreen {
    /// What pressing `u` would do. Only the data packs go out of date while installed.
    enum UpdateAction: Equatable {
        case fetch
        case install
        case nothing(String)
    }

    func updateAction(for tool: ToolStatus, _ ctx: AppContext) -> UpdateAction {
        guard DataPack.named(tool.id) != nil else {
            return .nothing(t("%@ is not something kmap updates", tool.name))
        }
        guard tool.isReady else { return .install }
        guard ctx.packNews[tool.id] != nil else {
            return .nothing(
                ctx.packsChecked
                    ? t("%@ is already the published one", tool.name) : t("still checking…")
            )
        }
        return .fetch
    }

    func update(_ tool: ToolStatus, _ ctx: AppContext) {
        guard !queue.isInstalling(tool.id) else {
            message = t("%@ is still installing", tool.name)
            return
        }
        switch updateAction(for: tool, ctx) {
        case .nothing(let said): message = said
        case .install: install(tool, ctx)
        case .fetch: start(tool, ctx, force: true)
        }
    }

    func remove(_ tool: ToolStatus, _ ctx: AppContext) {
        guard !queue.isInstalling(tool.id) else {
            message = t("%@ is still installing", tool.name)
            return
        }
        guard tool.removable else {
            message = t("%@ cannot be removed", tool.name)
            return
        }
        do {
            try ctx.toolchain.remove(tool.id, log: log)
            message = t("%@ removed", tool.name)
            ctx.refreshTools(force: true)
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// A root install is asked about first, every time; only `y` starts it.
    func install(_ tool: ToolStatus, _ ctx: AppContext) {
        guard !queue.isInstalling(tool.id) else {
            message =
                queue.isWaiting(tool.id)
                ? waitingNote(for: tool.id, ctx) : t("%@ is still installing", tool.name)
            return
        }
        if let command = ctx.toolchain.rootInstallCommand(for: tool.id) {
            awaitingRoot = tool.id
            message = t("this installs a system package as root:  %@   —  press y to go ahead", command)
            return
        }
        awaitingRoot = nil
        start(tool, ctx)
    }

    /// Everything a build needs, at once; what needs root is left for its own Enter.
    func installAllMissing(_ tools: [ToolStatus], _ ctx: AppContext) {
        let wanted = tools.filter {
            !$0.isFinished && $0.installable && !$0.isOptional && !queue.isInstalling($0.id)
        }
        guard !wanted.isEmpty else {
            message = t("nothing left to install")
            return
        }
        var asRoot: [String] = []
        for tool in wanted {
            if ctx.toolchain.rootInstallCommand(for: tool.id) != nil {
                asRoot.append(tool.name)
            } else {
                start(tool, ctx)
            }
        }
        if !asRoot.isEmpty {
            message = t("needs root, press Enter on its row: %@", asRoot.joined(separator: ", "))
        }
    }

    func start(_ tool: ToolStatus, _ ctx: AppContext, force: Bool = false) {
        guard force || !tool.isFinished else {
            message = t("%@ is already installed", tool.name)
            return
        }
        guard tool.installable else {
            message = tool.note ?? t("%@ has to be installed by hand", tool.name)
            return
        }
        message = nil
        if queue.admit(tool.id) {
            launch(tool, ctx)
        } else {
            message = waitingNote(for: tool.id, ctx)
        }
    }

    private func launch(_ tool: ToolStatus, _ ctx: AppContext) {
        let job = queue.begin(tool.id)
        let log = self.log
        let toolchain = ctx.toolchain
        let install =
            installer ?? { id, log, runner, progress in
                try await toolchain.install(id, log: log, runner: runner, progress: progress)
            }

        log.step(t("installing %@", tool.name))
        job.progress.begin(tool.name)
        job.task = Task { [weak self] in
            do {
                try await install(tool.id, log, job.runner, job.progress)
                log.ok(t("%@ installed", tool.name))
            } catch {
                // A stopped install is said once, by the key that stopped it.
                if !Task.isCancelled { log.error(error.localizedDescription) }
            }
            guard let self else { return }
            await MainActor.run { self.finished(tool.id, ctx) }
        }
    }

    private func finished(_ id: String, _ ctx: AppContext) {
        queue.finish(id)
        ctx.refreshTools(force: true)
        ctx.refreshPackNews(force: true)
        while let next = queue.takeReady() {
            if let tool = ctx.tools.first(where: { $0.id == next }) { launch(tool, ctx) }
        }
    }

    func stopEverything() {
        queue.stopAll()
        log.warn(t("stopped"))
        message = nil
    }

    func waitingNote(for id: String, _ ctx: AppContext) -> String {
        let names = queue.blockerNames(of: id) { blocker in
            ctx.tools.first { $0.id == blocker }?.name ?? blocker
        }
        return t("waiting for %@", names.joined(separator: ", "))
    }
}
