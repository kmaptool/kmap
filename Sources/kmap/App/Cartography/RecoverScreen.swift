import Foundation

/// Recovers a foreign map's look as a style of kmap's own: its elements are matched
/// against cached OSM data by geometry, and every picture that names a meaning is
/// written onto the number kmap's rules draw that meaning with. Where nothing cached
/// matches the map, the smallest useful region is offered; nothing is fetched unasked.
final class RecoverScreen: Screen {

    var page: Page { Page(t("recover the style"), keys: keys) }

    private var keys: [Hint] {
        if let offering { return offering.footerHints }
        switch phase {
        case .intro:
            return [Hint(key: Glyph.enter, label: t("start")), Hint(key: "esc", label: t("back"))]
        case .running, .downloading:
            return [Hint(key: "esc", label: t("cancel"))]
        case .cancelled:
            return [Hint(key: "esc", label: t("back"))]
        case .done:
            var hints: [Hint] = []
            if recovered, !saved {
                hints.append(Hint(key: Glyph.enter, label: t("save")))
            }
            hints.append(Hint(key: "esc", label: saved ? t("back") : t("discard")))
            return hints
        case .failed:
            return [Hint(key: "esc", label: t("back"))]
        }
    }

    private enum Phase { case intro, running, downloading, cancelled, done, failed }

    private let img: URL
    private let typ: URL
    private var phase: Phase = .intro
    private let log = Log()
    private let progress = RecoverProgress()
    private var work: Task<Void, Never>?
    private var startedAt = Date()
    private var report: StyleRecovery.Report?
    private var failure: String?
    private var saved = false
    private var message: String?

    /// The download offer, while it is up, and what saying yes would fetch.
    private var offering: Dialog?
    private var wanted: [Region] = []
    private var sizes: [String: Int64] = [:]
    /// The runners-up, shown beside the offer.
    private var alternatives: [(name: String, size: Int64)] = []
    private var downloader: Downloader?
    private var fetching = ""

    init(img: URL, typ: URL) {
        self.img = img
        self.typ = typ
    }

    /// Whether the recovery produced a style at all.
    private var recovered: Bool { !(report?.style ?? "").isEmpty }

    /// The codes nothing was written for, worst first: those that could not be settled,
    /// then those with no rule, and last those seen only once or twice.
    private var remainder: [StyleRecovery.Outcome] {
        func rank(_ status: StyleRecovery.Status) -> Int {
            switch status {
            case .mixed: return 0
            case .noRule: return 1
            default: return 2
            }
        }
        return (report?.outcomes.values.filter {
            $0.status == .mixed || $0.status == .noRule || $0.status == .singleWitness
        } ?? []).sorted {
            (rank($0.status), $1.witnesses) < (rank($1.status), $0.witnesses)
        }
    }

    /// Why a code was left alone, in as few words as the column holds.
    private func reason(_ status: StyleRecovery.Status) -> String {
        switch status {
        case .mixed: return t("draws several things")
        case .noRule: return t("no rule for it")
        case .singleWitness: return t("too few sightings")
        default: return ""
        }
    }

    func tick(_ ctx: AppContext) {}

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if var open = offering {
            switch open.handle(key) {
            case .confirmed:
                offering = nil
                download(ctx)
            case .cancelled:
                offering = nil
                phase = .cancelled
                message = nil
            case .none:
                offering = open
            }
            return .none
        }
        switch (phase, key) {
        case (.intro, .enter):
            start(ctx)
        case (.intro, .esc), (.failed, .esc), (.cancelled, .esc):
            return .pop
        case (.running, .esc), (.downloading, .esc):
            cancel()
        case (.done, .enter) where recovered && !saved:
            do {
                // The style this was opened from becomes the recovered one: in as the
                // map's own TYP, out as the same pictures on kmap's numbers. The
                // untouched original stays beside the library as it always has.
                try TypLibrary.save(report?.style ?? "", to: typ)
                // The reassignment list went with the old file: there are no foreign
                // numbers left to bend our rules onto.
                if let stale = TypLibrary.sheet(of: typ) { FileTools.removeIfPresent(stale) }
                saved = true
                ctx.styles.rescanStyles()
                message = t("%@ now draws this map's look",
                            typ.deletingPathExtension().lastPathComponent)
            } catch {
                message = error.localizedDescription
            }
        case (.done, .esc):
            return .pop
        case (_, .ctrl("c")):
            if phase == .running || phase == .downloading { cancel(); return .none }
            return .quit
        default: break
        }
        return .none
    }

    private func start(_ ctx: AppContext) {
        phase = .running
        startedAt = Date()
        let log = self.log
        let progress = self.progress
        let img = self.img
        // Bound once, strongly, for the task's life: a weak `self` read inside the hops
        // back to the main actor would be a captured var in concurrent code. Leaving the
        // screen cancels the task.
        work = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Derived against the pristine rule stage, never against whatever the
                // last build happened to hide or translate.
                let settings = SettingsStore()
                let catalog = StyleCatalog(settings: settings,
                                           toolchain: Toolchain(settings: settings))
                let neutral = try await catalog.neutralRulesForRecovery(
                    log: log, runner: ProcessRunner())
                defer { FileTools.removeIfPresent(neutral) }
                let report = try await StyleRecovery.run(
                    img: img, extracts: [], log: log, rulesDirectory: neutral,
                    progress: progress)
                await MainActor.run {
                    self.report = report
                    self.phase = .done
                }
            } catch is CancellationError {
                await MainActor.run { self.phase = .cancelled }
            } catch StyleRecovery.Trouble.noExtracts(let frame) {
                await MainActor.run { self.offer(ctx, frame: frame) }
            } catch {
                await MainActor.run {
                    self.failure = self.explain(error)
                    self.phase = .failed
                }
            }
        }
    }

    /// Stops the reading, the matching loop and any download.
    private func cancel() {
        downloader?.cancel()
        work?.cancel()
    }

    /// What went wrong, in actionable words: a URL error arrives as an NSError describing
    /// the session's internals rather than what to do about it.
    private func explain(_ error: Error) -> String {
        let code = (error as NSError).domain == NSURLErrorDomain
            ? (error as NSError).code : nil
        switch code {
        case NSURLErrorTimedOut:
            return t("the download server did not answer in time — try again, or later"
                   + " if it is busy")
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            return t("no connection to the download server — check the network and"
                   + " try again")
        case .some:
            return t("the download did not go through: %@", error.localizedDescription)
        case nil:
            return "\(error)"
        }
    }

    // MARK: The download offer

    /// Weighs the regions that would cover the map and offers the lightest worth having.
    /// A confirmed offer downloads into the cache a build reads, then restarts the run.
    private func offer(_ ctx: AppContext, frame: BBox) {
        let index = ctx.index
        let img = img
        work = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                if index.regions.isEmpty { try await index.load() }
                // Measured against the map's own tiles, not its frame: the frame is a
                // rectangle and spans ground a non-rectangular map never draws.
                let drawn = RegionSuggestion.drawnGround(of: img)
                let regions = RegionSuggestion.suggestedRegions(on: drawn, index: index)
                guard !regions.isEmpty else {
                    await MainActor.run {
                        self.failure = t("no region kmap can download overlaps this map (%@)",
                                         frame.display)
                        self.phase = .failed
                    }
                    return
                }
                let weighed = await Self.weighed(regions)
                guard let pick = RegionSuggestion.worthDownloading(weighed) ?? regions.first
                else { return }
                await MainActor.run {
                    self.wanted = [pick.region]
                    self.sizes = Dictionary(uniqueKeysWithValues:
                        weighed.map { ($0.0.region.id, $0.1) })
                    // The runners-up, limited to regions the map also stands on.
                    self.alternatives = weighed
                        .filter { $0.0.region.id != pick.region.id && $0.0.isInside == pick.isInside }
                        .sorted { $0.1 < $1.1 }
                        .prefix(2).map { ($0.0.region.name, $0.1) }
                    self.rebuildOffer()
                }
            } catch {
                await MainActor.run {
                    self.failure = self.explain(error)
                    self.phase = .failed
                }
            }
        }
    }

    /// The download size of every candidate, probed concurrently. Extract size does not
    /// follow area, so the choice is made on bytes rather than on ground covered.
    private static func weighed(_ regions: [RegionSuggestion.Candidate]) async
    -> [(RegionSuggestion.Candidate, Int64)] {
        await withTaskGroup(of: (RegionSuggestion.Candidate, Int64)?.self) { group in
            for candidate in regions {
                group.addTask {
                    guard let url = candidate.region.pbfURL,
                          let info = try? await Downloader.probe(url) else { return nil }
                    return (candidate, info.size)
                }
            }
            var out: [(RegionSuggestion.Candidate, Int64)] = []
            for await answer in group {
                if let answer { out.append(answer) }
            }
            return out
        }
    }

    private func rebuildOffer() {
        var detail = wanted.map { region -> (String, String) in
            (region.name, sizes[region.id].map { "≈ \(Fmt.bytes($0))" } ?? "…")
        }
        // The other candidates, listed under the one being offered.
        for other in alternatives {
            detail.append((other.name, "≈ \(Fmt.bytes(other.size))"))
        }
        offering = Dialog(
            title: t("Download a region?"),
            body: [t("No OSM data on this machine matches this map. Recovering the style"
                   + " does not need the whole map covered — the codes a style uses are"
                   + " used everywhere it draws, so one region inside the map is enough"
                   + " to read them."),
                   t("The first is what kmap would take; it lands in the same cache a"
                   + " build reads, so the next build has it too.")],
            detail: detail,
            confirm: t("download"),
            cancel: t("not now"),
            tone: .plain)
    }

    private func download(_ ctx: AppContext) {
        phase = .downloading
        startedAt = Date()
        let regions = wanted
        let log = self.log
        let downloader = Downloader(log: log)
        self.downloader = downloader
        work = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                for region in regions {
                    guard let url = region.pbfURL else { continue }
                    await MainActor.run { self.fetching = region.name }
                    try await downloader.download(
                        url: url,
                        to: RegionSuggestion.cacheDestination(for: region),
                        connections: 4)
                }
                await MainActor.run { self.start(ctx) }
            } catch is CancellationError {
                await MainActor.run { self.phase = .cancelled }
            } catch {
                await MainActor.run {
                    if self.work?.isCancelled == true {
                        self.phase = .cancelled
                    } else {
                        self.failure = self.explain(error)
                        self.phase = .failed
                    }
                }
            }
        }
    }

    // MARK: Rendering

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        switch phase {
        case .intro:
            renderIntro(into: s, rect: rect, theme: theme, y: &y)
        case .running:
            renderRunning(into: s, rect: rect, ctx: ctx, theme: theme, y: &y)
        case .downloading:
            renderDownloading(into: s, rect: rect, ctx: ctx, theme: theme, y: &y)
        case .cancelled:
            paragraph(t("cancelled — nothing was kept"), tone: theme.warn,
                      into: s, rect: rect, theme: theme, y: &y)
        case .failed:
            paragraph(t("it did not work out") + ": " + (failure ?? ""), tone: theme.danger,
                      into: s, rect: rect, theme: theme, y: &y)
        case .done:
            renderDone(into: s, rect: rect, theme: theme, y: &y)
        }

        // Drawn last, over everything else.
        offering?.render(into: s, rect: rect, theme: theme)
    }

    /// Wrapped prose, one tone, advancing `y` a line per chunk until the rect is full.
    private func paragraph(_ text: String, tone: Color, into s: Surface, rect: Rect,
                           theme: Theme, y: inout Int) {
        for chunk in wrapText(text, width: rect.w) {
            guard y < rect.maxY else { return }
            s.text(rect.x, y, chunk, Style(fg: tone, bg: theme.appBg))
            y += 1
        }
    }

    private func renderIntro(into s: Surface, rect: Rect, theme: Theme, y: inout Int) {
        func paragraph(_ text: String, tone: Color) {
            self.paragraph(text, tone: tone, into: s, rect: rect, theme: theme, y: &y)
        }
        paragraph(t("A TYP records how type codes are drawn. It does not record which"
                  + " code this map used for a forest or a trunk road."), tone: theme.text)
        y += 1
        paragraph(t("kmap works that out from the map itself: every element is looked"
                  + " up in OSM data by its geometry, and the code it was drawn with"
                  + " is tied to the thing it stands for."), tone: theme.text)
        y += 1
        paragraph(t("What comes out is kept with the imported TYP, and every build"
                  + " with that style applies it — the map comes out looking the way"
                  + " the original did."), tone: theme.text)
        y += 1
        paragraph(t("Reading the whole map takes a few minutes; you can stop it at"
                  + " any point."), tone: theme.faint)
        y += 1
        s.text(rect.x, y, t("map") + ": " + img.lastPathComponent,
               Style(fg: theme.dim, bg: theme.appBg))
    }

    private func renderRunning(into s: Surface, rect: Rect, ctx: AppContext, theme: Theme,
                               y: inout Int) {
        let snap = progress.snapshot
        s.text(rect.x, y, t("recovering %@", String(Widgets.spinner(ctx.frame))),
               Style(fg: theme.accent, bg: theme.appBg, bold: true))
        s.textRight(rect.maxX, y, Fmt.duration(Date().timeIntervalSince(startedAt)),
                    Style(fg: theme.dim, bg: theme.appBg))
        y += 2

        for (stage, title) in stages(for: snap) {
            guard y < rect.maxY - 2 else { break }
            let marker: String
            let tone: Color
            switch stage {
            case .done: marker = String(Glyph.check); tone = theme.ok
            case .running: marker = String(Widgets.spinner(ctx.frame)); tone = theme.accent
            case .pending: marker = "·"; tone = theme.faint
            }
            s.text(rect.x, y, marker, Style(fg: tone, bg: theme.appBg))
            // Cut with an ellipsis rather than at the column: a title that ends mid-word
            // says so, and one that ends on a preposition does not.
            s.text(rect.x + 2, y, truncate(title, to: RecoverScreen.titleWidth),
                   Style(fg: stage == .pending ? theme.faint : theme.text,
                         bg: theme.appBg, bold: stage == .running))
            if stage == .running {
                let detailX = rect.x + RecoverScreen.titleWidth + 4
                if let fraction = snap.fraction, rect.w > 50 {
                    let barWidth = min(28, max(10, rect.maxX - detailX - 2))
                    Widgets.progressBar(s, x: detailX, y: y, width: barWidth,
                                        fraction: fraction, theme: theme)
                } else if snap.done > 0 {
                    s.text(detailX, y, tn("%d element(s)", snap.done),
                           Style(fg: theme.dim, bg: theme.appBg))
                }
            }
            y += 1
        }
        y += 1
        for line in log.snapshot().suffix(max(0, rect.maxY - y - 1)) {
            guard y < rect.maxY else { break }
            s.text(rect.x, y, truncate(line.text, to: rect.w),
                   Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
    }

    private func renderDownloading(into s: Surface, rect: Rect, ctx: AppContext,
                                   theme: Theme, y: inout Int) {
        s.text(rect.x, y, t("downloading %@", String(Widgets.spinner(ctx.frame))),
               Style(fg: theme.accent, bg: theme.appBg, bold: true))
        s.textRight(rect.maxX, y, Fmt.duration(Date().timeIntervalSince(startedAt)),
                    Style(fg: theme.dim, bg: theme.appBg))
        y += 2
        if !fetching.isEmpty {
            s.text(rect.x, y, truncate(fetching, to: rect.w),
                   Style(fg: theme.text, bg: theme.appBg))
            y += 1
        }
        if let progress = downloader?.progress {
            Widgets.progressBar(s, x: rect.x, y: y, width: min(46, rect.w),
                                fraction: progress.fraction, theme: theme)
            y += 1
            if progress.total > 0 {
                s.text(rect.x, y, "\(Fmt.bytes(progress.received)) / \(Fmt.bytes(progress.total))",
                       Style(fg: theme.dim, bg: theme.appBg))
                y += 1
            }
        }
        y += 1
        for line in log.snapshot().suffix(max(0, rect.maxY - y - 1)) {
            guard y < rect.maxY else { break }
            s.text(rect.x, y, truncate(line.text, to: rect.w),
                   Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
    }

    private func renderDone(into s: Surface, rect: Rect, theme: Theme, y: inout Int) {
        func paragraph(_ text: String, tone: Color) {
            self.paragraph(text, tone: tone, into: s, rect: rect, theme: theme, y: &y)
        }
        guard let report else { return }
        let resolved = report.outcomes.values.filter { $0.status == .resolved }.count
        paragraph(tn("%d code(s) in this map", report.outcomes.count) + " · "
                  + tn("%d understood", resolved), tone: theme.strong)
        y += 1
        if !recovered {
            paragraph(t("Nothing to save: this map carries no look to take."),
                      tone: theme.text)
        }
        let rest = remainder
        if !rest.isEmpty {
            paragraph(tn("%d code(s) left alone — no rule of ours is aimed at them,"
                       + " so the map goes on drawing them as it did:",
                       rest.count), tone: theme.text)
            // Only as many rows as fit, with a count of the rest, so a list running
            // off the bottom does not read as the whole of it.
            let room = max(0, rect.maxY - y - 2)
            let shown = rest.prefix(room)
            for o in shown {
                let code = String(format: "%@ 0x%04x", String(o.kind.rawValue), o.type)
                let what = o.meaning.isEmpty ? t("nothing identified") : o.meaning
                let column = min(24, max(12, (rect.w - 12) / 3))
                s.text(rect.x + 2, y, code, Style(fg: theme.dim, bg: theme.appBg))
                s.text(rect.x + 12, y, reason(o.status),
                       Style(fg: theme.faint, bg: theme.appBg), limit: column - 1)
                s.text(rect.x + 12 + column, y,
                       truncate(what, to: max(0, rect.maxX - rect.x - 12 - column)),
                       Style(fg: theme.faint, bg: theme.appBg))
                y += 1
            }
            if shown.count < rest.count, y < rect.maxY {
                s.text(rect.x + 2, y, tn("and %d more", rest.count - shown.count),
                       Style(fg: theme.dim, bg: theme.appBg))
                y += 1
            }
            y += 1
        }
        if let message, y < rect.maxY {
            s.text(rect.x, y, truncate(message, to: rect.w),
                   Style(fg: theme.ok, bg: theme.appBg))
        }
    }

    // MARK: Stage list

    private enum StageState { case done, running, pending }

    /// Columns the stage's own words get, before the progress bar beside them.
    private static let titleWidth = 45

    /// The four stages a run goes through, each marked off as the progress passes it.
    private func stages(for snap: RecoverProgress.Snapshot) -> [(StageState, String)] {
        func state(_ order: Int) -> StageState {
            let now: Int
            switch snap.stage {
            case .preparing: now = 0
            case .reading: now = 1
            case .indexing, .matching: now = 2
            case .placing: now = 3
            case .deriving: now = 4
            }
            return order < now ? .done : order == now ? .running : .pending
        }
        var ground = t("matching against OSM data")
        if case .indexing(let name) = snap.stage {
            ground = t("matching against %@", name)
        } else if case .matching(let name) = snap.stage {
            ground = t("matching against %@", name)
        }
        var placing = t("identifying the rest by place")
        if case .placing(let name) = snap.stage {
            placing = t("identifying the rest by place in %@", name)
        }
        return [(state(0), t("preparing the map reader")),
                (state(1), t("reading the map")),
                (state(2), ground),
                (state(3), placing),
                (state(4), t("working out what the codes mean"))]
    }
}
