import Foundation

/// Recovers a foreign map's look as a style of kmap's own: its elements are matched
/// against cached OSM data by geometry, and every picture that names a meaning is
/// written onto the number kmap draws that meaning with. Where nothing cached matches,
/// the smallest useful region is offered; nothing is fetched unasked.
final class RecoverScreen: Screen {
    var page: Page { Page(t("recover the style"), keys: keys) }

    private var keys: [Hint] {
        if let offering { return offering.footerHints }
        switch phase {
        case .intro:
            return [Hint(key: Glyph.enter, label: t("start")), Hint(key: "esc", label: t("back"))]
        case .running, .downloading:
            return [Hint(key: "esc", label: t("cancel"))]
        case .cancelled, .failed:
            return [Hint(key: "esc", label: t("back"))]
        case .done:
            var hints: [Hint] = []
            if recovered, !saved { hints.append(Hint(key: Glyph.enter, label: t("save"))) }
            hints.append(Hint(key: "esc", label: saved ? t("back") : t("discard")))
            return hints
        }
    }

    enum Phase { case intro, running, downloading, cancelled, done, failed }

    let img: URL
    let typ: URL
    var phase: Phase = .intro
    let log = Log()
    let progress = RecoverProgress()
    var work: Task<Void, Never>?
    var startedAt = Date()
    var report: StyleRecovery.Report?
    var failure: String?
    var saved = false
    var message: String?
    /// The download offer, about the regions it would fetch.
    var offering: Question<[Region]>?
    var downloader: Downloader?
    private var runner: ProcessRunner?
    var fetching = ""

    init(img: URL, typ: URL) {
        self.img = img
        self.typ = typ
    }

    var recovered: Bool { !(report?.style ?? "").isEmpty }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if let (answer, regions) = offering.take(key) {
            switch answer {
            case .confirmed: download(regions, ctx)
            case .cancelled:
                phase = .cancelled
                message = nil
            case .none: break
            }
            return .none
        }
        switch (phase, key) {
        case (.intro, .enter):
            start(ctx)
        case (.intro, .esc), (.failed, .esc), (.cancelled, .esc), (.done, .esc):
            return .pop
        case (.running, .esc), (.downloading, .esc):
            cancel()
        case (.done, .enter) where recovered && !saved:
            save(ctx)
        case (_, .ctrl("c")):
            if phase == .running || phase == .downloading { cancel(); return .none }
            return .quit
        default: break
        }
        return .none
    }

    /// The style this was opened from becomes the recovered one; the untouched original
    /// stays beside the library. The reassignment list went with the old file.
    private func save(_ ctx: AppContext) {
        do {
            try TypLibrary.save(report?.style ?? "", to: typ)
            if let stale = TypLibrary.sheet(of: typ) { FileTools.removeIfPresent(stale) }
            saved = true
            ctx.styles.rescanStyles()
            message = t("%@ now draws this map's look", typ.deletingPathExtension().lastPathComponent)
        } catch {
            message = error.localizedDescription
        }
    }

    func start(_ ctx: AppContext) {
        phase = .running
        startedAt = Date()
        let log = self.log
        let progress = self.progress
        let img = self.img
        // Esc cancels the task, the runner and any download.
        let runner = ProcessRunner()
        self.runner = runner
        work = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Against the pristine rule stage, never against what the last build hid.
                let settings = SettingsStore()
                let catalog = StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
                let neutral = try await catalog.neutralRulesForRecovery(log: log, runner: runner)
                defer { FileTools.removeIfPresent(neutral) }
                let report = try await StyleRecovery.run(
                    img: img,
                    extracts: [],
                    log: log,
                    rulesDirectory: neutral,
                    progress: progress
                )
                await MainActor.run {
                    self.report = report
                    self.phase = .done
                }
            } catch is CancellationError {
                await MainActor.run { self.phase = .cancelled }
            } catch StyleRecovery.Trouble.noExtracts(let frame) {
                await MainActor.run { self.offer(ctx, frame: frame) }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    /// Stops the reading, the matching loop and any download.
    private func cancel() {
        downloader?.cancel()
        runner?.cancel()
        work?.cancel()
    }

    func fail(_ error: Error) {
        failure = explain(error)
        phase = .failed
    }

    /// A URL error describes the session's internals rather than what to do about it.
    private func explain(_ error: Error) -> String {
        let code = (error as NSError).domain == NSURLErrorDomain ? (error as NSError).code : nil
        switch code {
        case NSURLErrorTimedOut:
            return t("the download server did not answer in time — try again, or later if it is busy")
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            return t("no connection to the download server — check the network and try again")
        case .some:
            return t("the download did not go through: %@", error.localizedDescription)
        case nil:
            return "\(error)"
        }
    }
}
