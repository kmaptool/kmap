import Foundation

/// Watches a running build: stage list on top, live output below.
final class BuildScreen: Screen {
    var page: Page {
        // The primary region plus a count: several names overflow the bar.
        let extra = pipeline.recipe.extraRegions.count
        return Page(t("build"), subject: pipeline.recipe.region.name + (extra > 0 ? " +\(extra)" : ""), keys: keys)
    }

    private var keys: [Hint] {
        let snapshot = pipeline.snapshot()
        let detail = Hint(key: "v", label: showingDetail ? t("hide detail") : t("detail"))
        if snapshot.finished {
            var hints = [Hint(key: Glyph.enter, label: t("done"))]
            if !Self.succeeded(snapshot) { hints.append(Hint(key: "esc", label: t("back to the map's settings"))) }
            if Platform.canReveal { hints.append(Hint(key: "o", label: Platform.revealLabel())) }
            hints += [Hint(key: "l", label: t("library")), Hint(key: "↑↓", label: t("scroll log")), detail]
            return hints
        }
        return [Hint(key: "^C", label: t("cancel build")), Hint(key: "↑↓", label: t("scroll log")), detail]
    }

    private static let titleColumns = 24
    private static let detailColumn = 26
    private static let leastWidthForBars = 60
    private static let barWidth = 10...24
    private static let roomAfterBar = 30

    private let pipeline: BuildPipeline
    private var started = false
    private var logScroll = 0
    /// Whether the pane shows what the tools printed as well as what kmap says.
    private var showingDetail = false

    init(pipeline: BuildPipeline) {
        self.pipeline = pipeline
    }

    func tick(_ ctx: AppContext) {
        guard !started else { return }
        started = true
        pipeline.start()
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let snapshot = pipeline.snapshot()
        switch key.command {
        case .ctrl("c"):
            if snapshot.finished { return .quit }
            pipeline.cancel()
        case .up, .char("k"): logScroll += 1
        case .down, .char("j"): logScroll = max(0, logScroll - 1)
        case .pageUp: logScroll += ListState.pageStep
        case .pageDown: logScroll = max(0, logScroll - ListState.pageStep)
        case .end: logScroll = 0
        case .char("v"): showingDetail.toggle()
        case .enter:
            if snapshot.finished { return .popToRoot }
        case .char("o"):
            // Reveal rather than open: the next step is copying the file to the device.
            if snapshot.finished, let first = snapshot.outputs.first { Reveal.show(first.url) }
        case .char("l"):
            if snapshot.finished { return .replace(LibraryScreen()) }
        case .esc:
            // Only once the work is over: a running pipeline would be unreachable. An unfinished
            // build goes back to its form, its changes kept.
            if snapshot.finished { return Self.succeeded(snapshot) ? .popToRoot : .pop }
        default: break
        }
        return .none
    }

    private static func succeeded(_ snapshot: BuildPipeline.Snapshot) -> Bool {
        snapshot.failure == nil && !snapshot.cancelled
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

    private func renderOverallBar(
        _ snapshot: BuildPipeline.Snapshot,
        into s: Surface,
        rect: Rect,
        ctx: AppContext,
        theme: Theme,
        y: inout Int
    ) {
        let elapsed = (snapshot.finishedAt ?? Date()).timeIntervalSince(snapshot.startedAt)
        let headline: String
        let tone: Color
        if snapshot.failure != nil {
            headline = t("failed")
            tone = theme.danger
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
        Widgets.progressBar(
            s,
            x: rect.x,
            y: y,
            width: rect.w,
            fraction: snapshot.overall,
            theme: theme,
            fillColor: tone
        )
        y += 2
    }

    /// One row per stage: marker, title, and either its bar or its detail line.
    private func renderStages(
        _ snapshot: BuildPipeline.Snapshot,
        into s: Surface,
        rect: Rect,
        ctx: AppContext,
        theme: Theme,
        y: inout Int
    ) {
        for stage in snapshot.stages {
            guard y < rect.maxY - 4 else { break }
            // A held stage reads as not started, like the ones after it.
            let held = stage.isHeld(among: snapshot.stages)
            let active = stage.status == .running && !held
            let (marker, markerTone) = marker(for: held ? .pending : stage.status, theme: theme, frame: ctx.frame)
            // A stage that runs beside the others: a rule down the gutter and an indent.
            let indent = stage.id.runsBeside ? 2 : 0
            if stage.id.runsBeside {
                s.put(rect.x, y, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))
            }
            s.text(rect.x + indent, y, marker, Style(fg: markerTone, bg: theme.appBg))
            let quiet = stage.status == .pending || stage.status == .skipped || held
            s.text(
                rect.x + indent + 2,
                y,
                stage.id.title,
                Style(fg: quiet ? theme.faint : theme.text, bg: theme.appBg, bold: active),
                limit: max(0, Self.titleColumns - indent)
            )

            let detailX = rect.x + Self.detailColumn
            if active, let fraction = stage.fraction, rect.w > Self.leastWidthForBars {
                let barWidth = min(
                    Self.barWidth.upperBound,
                    max(Self.barWidth.lowerBound, rect.w - detailX - Self.roomAfterBar)
                )
                Widgets.progressBar(s, x: detailX, y: y, width: barWidth, fraction: fraction, theme: theme)
                s.text(
                    detailX + barWidth + 2,
                    y,
                    truncate(stage.detail, to: max(0, rect.maxX - detailX - barWidth - 2)),
                    Style(fg: theme.dim, bg: theme.appBg)
                )
            } else if !held, !stage.detail.isEmpty {
                s.text(
                    detailX,
                    y,
                    truncate(stage.detail, to: max(0, rect.maxX - detailX)),
                    Style(fg: active ? theme.dim : theme.faint, bg: theme.appBg)
                )
            }
            y += 1
        }
    }

    private func marker(for status: BuildPipeline.StageStatus, theme: Theme, frame: Int) -> (String, Color) {
        switch status {
        case .pending: return ("·", theme.faint)
        case .running: return (String(Widgets.spinner(frame)), theme.accent)
        case .done: return (String(Glyph.check), theme.ok)
        case .skipped: return ("–", theme.faint)
        case .failed: return (String(Glyph.cross), theme.danger)
        }
    }

    /// The failure, or the finished outputs and where they landed.
    private func renderResult(
        _ snapshot: BuildPipeline.Snapshot,
        into s: Surface,
        rect: Rect,
        theme: Theme,
        y: inout Int
    ) {
        if let failure = snapshot.failure {
            y = s.paragraph(
                failure,
                x: rect.x,
                y: y,
                width: rect.w,
                style: Style(fg: theme.danger, bg: theme.appBg),
                maxY: rect.maxY - 2
            )
            y += 1
        } else if snapshot.finished && !snapshot.outputs.isEmpty {
            // Where not every file has a row, the heading says how many there are.
            let rows = rect.maxY - 2 - (y + 1)
            let count = snapshot.outputs.count
            s.sectionRule(
                rect,
                y,
                count > rows ? t("files written") + " · \(count)" : t("files written"),
                labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
            )
            y += 1
            for (at, output) in snapshot.outputs.enumerated() {
                guard y < rect.maxY - 2 else { break }
                // The last row there is room for says how many more did not fit, or how
                // many there are where none fit.
                let left = snapshot.outputs.count - at
                if left > 1, y == rect.maxY - 3 {
                    let count = at == 0 ? tn("%d file(s)", left) : tn("and %d more", left)
                    s.text(rect.x, y, count, Style(fg: theme.dim, bg: theme.appBg))
                    y += 1
                    break
                }
                let size = Fmt.bytes(output.size)
                s.text(
                    rect.x,
                    y,
                    truncateMiddle(output.name, to: max(0, rect.w - size.count - 2)),
                    Style(fg: theme.ok, bg: theme.appBg, bold: true)
                )
                s.textRight(rect.maxX, y, size, Style(fg: theme.dim, bg: theme.appBg))
                y += 1
            }
            guard y < rect.maxY - 1 else { return }
            s.text(
                rect.x,
                y,
                truncateMiddle(Paths.display(pipeline.recipe.destinationDirectory), to: rect.w),
                Style(fg: theme.faint, bg: theme.appBg)
            )
            y += 2
        }
    }

    /// The log, scrolled back however far the person has gone.
    private func renderLog(into s: Surface, rect: Rect, theme: Theme, y: inout Int) {
        guard y < rect.maxY - 1 else { return }
        let logRect = Rect(x: rect.x, y: y + 1, w: rect.w, h: max(0, rect.maxY - y - 1))
        let lines = pipeline.log.snapshot().filter { showingDetail || $0.severity > .debug }
        // Held where the first line meets the top, so the label and the next key down
        // start from where the pane really is.
        logScroll = Widgets.logScroll(logScroll, lines: lines.count, height: logRect.h)
        s.sectionRule(
            rect,
            y,
            logScroll > 0 ? t("log") + " · " + t("scrolled back %d", logScroll) : t("log"),
            labelStyle: Style(fg: theme.dim, bg: theme.appBg),
            ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
        )
        y += 1
        Widgets.logPane(s, rect: logRect, lines: lines, theme: theme, scrollOffset: logScroll)
    }
}
