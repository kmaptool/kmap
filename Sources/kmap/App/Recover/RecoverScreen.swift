import Foundation

/// Recovers a foreign map's look as a style of kmap's own: its elements are matched
/// against cached OSM data by geometry, and every picture that names a meaning is
/// written onto the number kmap draws that meaning with. Where the cached data falls
/// short, the region holding most of the map is offered; nothing is fetched unasked.
final class RecoverScreen: Screen {
    var page: Page { Page(t("recover the style"), keys: keys) }

    private var keys: [Hint] {
        if let offering { return offering.footerHints }
        if let asking { return asking.footerHints }
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
    var message: String? { didSet { messageIsError = false } }
    private(set) var messageIsError = false
    /// The download offer, about the regions it would fetch.
    var offering: Question<[Region]>?
    /// Set once no more ground can be had: the run goes on with what there is.
    var anyGround = false
    /// Saving over the style, or leaving the recovery unsaved: the route a yes takes, nil
    /// for the save.
    var asking: Question<Route?>?
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
                stopped()
                message = nil
            case .none: break
            }
            return .none
        }
        if let (answer, leaving) = asking.take(key) {
            guard answer == .confirmed else { return .none }
            guard let leaving else {
                save(ctx)
                return .none
            }
            return leaving
        }
        // Minutes of reading, not saved anywhere else: leaving them is asked about.
        let unsaved = phase == .done && recovered && !saved
        switch (phase, key) {
        case (.intro, .enter):
            start(ctx)
        case (.done, .esc) where unsaved:
            askToLeave(.pop)
        case (.intro, .esc), (.failed, .esc), (.cancelled, .esc), (.done, .esc):
            return .pop
        case (.running, .esc), (.downloading, .esc):
            cancel()
        case (.done, .enter) where unsaved:
            askToSave()
        case (_, .ctrl("c")):
            if phase == .running || phase == .downloading { cancel(); return .none }
            if unsaved { askToLeave(.quit); return .none }
            return .quit
        default: break
        }
        return .none
    }

    private func askToLeave(_ route: Route) {
        asking = Question(
            dialog: Dialog(
                title: t("Leave the recovery"),
                body: [
                    t("The look read from this map is not saved: leaving drops it, and reading it again takes as long.")
                ],
                confirm: t("leave"),
                cancel: t("stay")
            ),
            subject: route
        )
    }

    /// As restoring a style asks: what was changed in it since is gone after.
    private func askToSave() {
        asking = Question(
            dialog: Dialog(
                title: t("Overwrite"),
                body: [
                    t(
                        "%@ will be rewritten with this map's look. Everything changed in it since, and its reassignment list, is lost.",
                        typ.deletingPathExtension().lastPathComponent
                    )
                ],
                confirm: t("save"),
                cancel: t("cancel"),
                tone: .plain
            ),
            subject: nil
        )
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
            messageIsError = true
        }
    }

    /// A run cut short leaves an earlier one's result up.
    func stopped() {
        phase = report == nil ? .cancelled : .done
    }

    func start(_ ctx: AppContext) {
        phase = .running
        startedAt = Date()
        // A run after one that went through starts its stages over.
        progress.move(to: .preparing)
        let log = self.log
        let progress = self.progress
        let img = self.img
        let index = ctx.index
        let anyGround = anyGround
        let leftBefore = report?.remainder
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
                    progress: progress,
                    anyGround: anyGround,
                    lookingForMore: !anyGround
                )
                // A region read for the codes it might settle that settled none: no more is
                // offered. Found before the result shows, so the question does not come up
                // under a key.
                let gained = leftBefore.map { report.settled(of: $0) > 0 } ?? true
                let more = gained ? await Self.groundToAdd(after: report, index: index) : nil
                await MainActor.run {
                    self.report = report
                    self.phase = .done
                    // Asked here, where Esc is handled: one pressed meanwhile gets no question.
                    if let more, self.work?.isCancelled != true, let left = report.remainder {
                        self.present(more.region, size: more.size, settling: more.codes, of: left)
                    }
                }
            } catch is CancellationError {
                await MainActor.run { self.stopped() }
            } catch StyleRecovery.Trouble.noExtracts(let frame) {
                await MainActor.run { self.offer(ctx, frame: frame, short: false) }
            } catch let trouble as StyleRecovery.Trouble where trouble.isTooLittleGround {
                // The cached extracts graze the map: the right one is offered for download.
                log.warn("\(trouble)")
                let frame = RegionSuggestion.frame(of: img)
                await MainActor.run { self.offer(ctx, frame: frame, short: true) }
            } catch  where Task.isCancelled {
                // A killed reader or unpacker fails in words of its own.
                await MainActor.run { self.stopped() }
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
        fail(saying: explain(error))
    }

    /// What an earlier run read stays up, with the trouble said beside it.
    func fail(saying trouble: String) {
        guard report == nil else {
            message = trouble
            messageIsError = true
            phase = .done
            return
        }
        failure = trouble
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
            return Self.explain(trouble: error) ?? ErrorWords.of(error)
        }
    }

    /// A recovery's refusal in the screen's words: the CLI's name a flag to pass.
    private static func explain(trouble error: Error) -> String? {
        guard let trouble = error as? StyleRecovery.Trouble else { return nil }
        switch trouble {
        case .noTiles: return t("the file holds no map tiles — is it a Garmin .img?")
        case .noSuchMap(let url): return t("no such map: %@", Paths.display(url))
        case .noSuchExtract(let url): return t("no such extract: %@", Paths.display(url))
        case .unreadableExtract(let url, let why): return t("%@ cannot be read: %@", url.lastPathComponent, "\(why)")
        case .noExtracts, .extractMissesMap, .tooLittleGround: return nil
        }
    }
}
