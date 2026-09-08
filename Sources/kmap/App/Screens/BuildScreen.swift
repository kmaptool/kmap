import Foundation

/// Watches a running build: stage list on top, live output below.
final class BuildScreen: Screen {
    // The primary region's name plus a count of the rest: several names spelled out
    // overflow the bar.
    var page: Page {
        let extra = pipeline.recipe.extraRegions.count
        return Page(t("build"),
                    subject: pipeline.recipe.region.name + (extra > 0 ? " +\(extra)" : ""),
                    keys: keys)
    }

    private var keys: [Hint] {
        let snapshot = pipeline.snapshot()
        if snapshot.finished {
            var hints = [Hint(key: Glyph.enter, label: t("done"))]
            if Platform.canReveal { hints.append(Hint(key: "o", label: Platform.revealLabel())) }
            hints += [Hint(key: "l", label: t("library")),
                      Hint(key: "↑↓", label: t("scroll log")),
                      Hint(key: "v", label: showingDetail ? t("hide detail") : t("detail"))]
            return hints
        }
        return [Hint(key: "^C", label: t("cancel build")),
                Hint(key: "↑↓", label: t("scroll log")),
                Hint(key: "v", label: showingDetail ? t("hide detail") : t("detail"))]
    }

    private let pipeline: BuildPipeline
    private var started = false
    private var logScroll = 0
    /// Whether the pane shows what the tools printed as well as what kmap says about it.
    /// The log holds both either way, so this hides rather than discards.
    private var showingDetail = false

    init(pipeline: BuildPipeline) {
        self.pipeline = pipeline
    }

    func tick(_ ctx: AppContext) {
        if !started {
            started = true
            pipeline.start()
        }
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let snapshot = pipeline.snapshot()
        switch key.command {
        case .ctrl("c"):
            if snapshot.finished { return .quit }
            pipeline.cancel()
        case .up, .char("k"): logScroll += 1
        case .down, .char("j"): logScroll = max(0, logScroll - 1)
        case .pageUp: logScroll += 10
        case .pageDown: logScroll = max(0, logScroll - 10)
        case .end: logScroll = 0
        case .char("v"): showingDetail.toggle()
        case .enter:
            if snapshot.finished { return .popToRoot }
        case .char("o"):
            // Reveal rather than open: the build drops the .img in a dated folder beside
            // earlier ones, and the next step is copying it to the device.
            if snapshot.finished, let first = snapshot.outputs.first,
               let command = Platform.revealCommand(for: first.url) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command.executable)
                process.arguments = command.arguments
                try? process.run()
            }
        case .char("l"):
            if snapshot.finished { return .replace(LibraryScreen()) }
        case .esc:
            // Only once the work is over: a running pipeline would be unreachable after
            // this screen is gone, and a second build could start over the same work
            // directory.
            if snapshot.finished { return .popToRoot }
        default: break
        }
        return .none
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let snapshot = pipeline.snapshot()
        var y = rect.y

        renderOverallBar(snapshot, into: s, rect: rect, ctx: ctx, theme: theme, y: &y)
        renderStages(snapshot, into: s, rect: rect, ctx: ctx, theme: theme, y: &y)
        y += 1
        renderResult(snapshot, into: s, rect: rect, theme: theme, y: &y)
        renderLog(into: s, rect: rect, theme: theme, y: &y)
    }

    /// The headline, the wall clock, and the whole build's bar.
    private func renderOverallBar(_ snapshot: BuildPipeline.Snapshot, into s: Surface,
                                  rect: Rect, ctx: AppContext, theme: Theme, y: inout Int) {
        let elapsed = (snapshot.finishedAt ?? Date()).timeIntervalSince(snapshot.startedAt)

        let headline: String
        let tone: Color
        if let failure = snapshot.failure {
            headline = t("failed")
            tone = theme.danger
            _ = failure
        } else if snapshot.cancelled {
            headline = t("cancelled")
            tone = theme.warn
        } else if snapshot.finished {
            headline = t("done")
            tone = theme.ok
        } else {
            headline = t("building %@", String(Widgets.spinner(ctx.frame)))
            tone = theme.accent
        }

        s.text(rect.x, y, headline, Style(fg: tone, bg: theme.appBg, bold: true))
        s.textRight(rect.maxX, y, Fmt.duration(elapsed), Style(fg: theme.dim, bg: theme.appBg))
        y += 1
        Widgets.progressBar(s, x: rect.x, y: y, width: rect.w,
                            fraction: snapshot.overall, theme: theme, fillColor: tone)
        y += 2
    }

    /// One row per stage: marker, title, and either its bar or its detail line.
    private func renderStages(_ snapshot: BuildPipeline.Snapshot, into s: Surface,
                              rect: Rect, ctx: AppContext, theme: Theme, y: inout Int) {
        for stage in snapshot.stages {
            guard y < rect.maxY - 4 else { break }
            let marker: String
            let markerTone: Color
            switch stage.status {
            case .pending: marker = "·"; markerTone = theme.faint
            case .running: marker = String(Widgets.spinner(ctx.frame)); markerTone = theme.accent
            case .done: marker = String(Glyph.check); markerTone = theme.ok
            case .skipped: marker = "–"; markerTone = theme.faint
            case .failed: marker = String(Glyph.cross); markerTone = theme.danger
            }

            // A stage that runs beside the others is drawn beside them: a rule down the
            // gutter and two columns of indent, so the list is not read top to bottom.
            let indent = stage.id.runsBeside ? 2 : 0
            if stage.id.runsBeside {
                s.put(rect.x, y, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))
            }
            s.text(rect.x + indent, y, marker, Style(fg: markerTone, bg: theme.appBg))
            let titleTone = stage.status == .pending || stage.status == .skipped ? theme.faint : theme.text
            s.text(rect.x + indent + 2, y, stage.id.title,
                   Style(fg: titleTone, bg: theme.appBg,
                         bold: stage.status == .running),
                   limit: max(0, 24 - indent))

            let detailX = rect.x + 26
            if stage.status == .running, let fraction = stage.fraction, rect.w > 60 {
                let barWidth = min(24, max(10, rect.w - detailX - 30))
                Widgets.progressBar(s, x: detailX, y: y, width: barWidth,
                                    fraction: fraction, theme: theme)
                s.text(detailX + barWidth + 2, y,
                       truncate(stage.detail, to: max(0, rect.maxX - detailX - barWidth - 2)),
                       Style(fg: theme.dim, bg: theme.appBg))
            } else if !stage.detail.isEmpty {
                s.text(detailX, y, truncate(stage.detail, to: max(0, rect.maxX - detailX)),
                       Style(fg: stage.status == .running ? theme.dim : theme.faint, bg: theme.appBg))
            }
            y += 1
        }
    }

    /// The failure, or the finished outputs and where they landed.
    private func renderResult(_ snapshot: BuildPipeline.Snapshot, into s: Surface,
                              rect: Rect, theme: Theme, y: inout Int) {
        if let failure = snapshot.failure {
            for chunk in wrapText(failure, width: rect.w) {
                guard y < rect.maxY - 2 else { break }
                s.text(rect.x, y, chunk, Style(fg: theme.danger, bg: theme.appBg))
                y += 1
            }
            y += 1
        } else if snapshot.finished && !snapshot.outputs.isEmpty {
            s.sectionRule(rect, y, t("output"),
                          labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                          ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
            y += 1
            for output in snapshot.outputs {
                guard y < rect.maxY - 2 else { break }
                s.text(rect.x, y, output.name, Style(fg: theme.ok, bg: theme.appBg, bold: true))
                s.textRight(rect.maxX, y, Fmt.bytes(output.size),
                            Style(fg: theme.dim, bg: theme.appBg))
                y += 1
            }
            guard y < rect.maxY - 1 else { return }
            s.text(rect.x, y, Paths.display(pipeline.recipe.destinationDirectory),
                   Style(fg: theme.faint, bg: theme.appBg))
            y += 2
        }
    }

    /// The running log, scrolled back however far the user has gone.
    private func renderLog(into s: Surface, rect: Rect, theme: Theme, y: inout Int) {
        guard y < rect.maxY - 1 else { return }
        s.sectionRule(rect, y, logScroll > 0
                        ? t("output") + " · " + t("scrolled back %d", logScroll)
                        : t("output"),
                      labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                      ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
        y += 1

        let logRect = Rect(x: rect.x, y: y, w: rect.w, h: max(0, rect.maxY - y))
        let lines = pipeline.log.snapshot().filter {
            showingDetail || $0.severity > .debug
        }
        logScroll = min(logScroll, max(0, lines.count - 1))
        Widgets.logPane(s, rect: logRect, lines: lines, theme: theme, scrollOffset: logScroll)
    }
}
