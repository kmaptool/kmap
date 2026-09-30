import Foundation

/// Drawing the recovery: the explanation, the stage list while it runs, the download,
/// and what came of it.
extension RecoverScreen {
    /// Columns the stage's own words get, before the progress bar beside them.
    private static let titleWidth = 45
    private static let leastWidthForBars = 50
    private static let barWidth = 10...28
    private static let downloadBarWidth = 46
    private static let codeColumn = 12
    private static let reasonColumn = 12...24

    private enum StageState { case done, running, pending }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y
        switch phase {
        case .intro: renderIntro(into: s, rect: rect, theme: theme, y: &y)
        case .running: renderRunning(into: s, rect: rect, ctx: ctx, theme: theme, y: &y)
        case .downloading: renderDownloading(into: s, rect: rect, ctx: ctx, theme: theme, y: &y)
        case .cancelled:
            s.paragraph(
                t("cancelled — nothing was kept"),
                x: rect.x,
                y: y,
                width: rect.w,
                style: Style(fg: theme.warn, bg: theme.appBg),
                maxY: rect.maxY
            )
        case .failed:
            s.paragraph(
                t("it did not work out") + ": " + (failure ?? ""),
                x: rect.x,
                y: y,
                width: rect.w,
                style: Style(fg: theme.danger, bg: theme.appBg),
                maxY: rect.maxY
            )
        case .done: renderDone(into: s, rect: rect, theme: theme, y: &y)
        }
        offering?.render(into: s, rect: rect, theme: theme)
    }

    private func renderIntro(into s: Surface, rect: Rect, theme: Theme, y: inout Int) {
        func paragraph(_ text: String, tone: Color) {
            y =
                s.paragraph(
                    text,
                    x: rect.x,
                    y: y,
                    width: rect.w,
                    style: Style(fg: tone, bg: theme.appBg),
                    maxY: rect.maxY
                ) + 1
        }
        paragraph(
            t(
                "A TYP records how type codes are drawn. It does not record which code this map used for a forest or a trunk road."
            ),
            tone: theme.text
        )
        paragraph(
            t(
                "kmap works that out from the map itself: every element is looked"
                    + " up in OSM data by its geometry, and the code it was drawn with"
                    + " is tied to the thing it stands for."
            ),
            tone: theme.text
        )
        paragraph(
            t(
                "What comes out is kept with the imported TYP, and every build"
                    + " with that style applies it — the map comes out looking the way"
                    + " the original did."
            ),
            tone: theme.text
        )
        paragraph(t("Reading the whole map takes a few minutes; you can stop it at any point."), tone: theme.faint)
        s.text(rect.x, y, t("map") + ": " + img.lastPathComponent, Style(fg: theme.dim, bg: theme.appBg))
    }

    private func renderRunning(into s: Surface, rect: Rect, ctx: AppContext, theme: Theme, y: inout Int) {
        let snap = progress.snapshot
        s.text(
            rect.x,
            y,
            t("recovering %@", String(Widgets.spinner(ctx.frame))),
            Style(fg: theme.accent, bg: theme.appBg, bold: true)
        )
        s.textRight(
            rect.maxX,
            y,
            Fmt.duration(Date().timeIntervalSince(startedAt)),
            Style(fg: theme.dim, bg: theme.appBg)
        )
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
            // Cut with an ellipsis, so a title that ends mid-word says so.
            s.text(
                rect.x + 2,
                y,
                truncate(title, to: Self.titleWidth),
                Style(fg: stage == .pending ? theme.faint : theme.text, bg: theme.appBg, bold: stage == .running)
            )
            if stage == .running {
                let detailX = rect.x + Self.titleWidth + 4
                if let fraction = snap.fraction, rect.w > Self.leastWidthForBars {
                    let barWidth = min(Self.barWidth.upperBound, max(Self.barWidth.lowerBound, rect.maxX - detailX - 2))
                    Widgets.progressBar(s, x: detailX, y: y, width: barWidth, fraction: fraction, theme: theme)
                } else if snap.done > 0 {
                    s.text(detailX, y, tn("%d element(s)", snap.done), Style(fg: theme.dim, bg: theme.appBg))
                }
            }
            y += 1
        }
        y += 1
        drawLog(into: s, rect: rect, theme: theme, y: &y)
    }

    private func renderDownloading(into s: Surface, rect: Rect, ctx: AppContext, theme: Theme, y: inout Int) {
        s.text(
            rect.x,
            y,
            t("downloading %@", String(Widgets.spinner(ctx.frame))),
            Style(fg: theme.accent, bg: theme.appBg, bold: true)
        )
        s.textRight(
            rect.maxX,
            y,
            Fmt.duration(Date().timeIntervalSince(startedAt)),
            Style(fg: theme.dim, bg: theme.appBg)
        )
        y += 2
        if !fetching.isEmpty {
            s.text(rect.x, y, truncate(fetching, to: rect.w), Style(fg: theme.text, bg: theme.appBg))
            y += 1
        }
        if let progress = downloader?.progress {
            Widgets.progressBar(
                s,
                x: rect.x,
                y: y,
                width: min(Self.downloadBarWidth, rect.w),
                fraction: progress.fraction,
                theme: theme
            )
            y += 1
            if progress.total > 0 {
                s.text(
                    rect.x,
                    y,
                    "\(Fmt.bytes(progress.received)) / \(Fmt.bytes(progress.total))",
                    Style(fg: theme.dim, bg: theme.appBg)
                )
                y += 1
            }
        }
        y += 1
        drawLog(into: s, rect: rect, theme: theme, y: &y)
    }

    private func drawLog(into s: Surface, rect: Rect, theme: Theme, y: inout Int) {
        for line in log.snapshot().suffix(max(0, rect.maxY - y - 1)) {
            guard y < rect.maxY else { break }
            s.text(rect.x, y, truncate(line.text, to: rect.w), Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
    }

    private func renderDone(into s: Surface, rect: Rect, theme: Theme, y: inout Int) {
        func paragraph(_ text: String, tone: Color) {
            y = s.paragraph(
                text,
                x: rect.x,
                y: y,
                width: rect.w,
                style: Style(fg: tone, bg: theme.appBg),
                maxY: rect.maxY
            )
        }
        guard let report else { return }
        let resolved = report.outcomes.values.filter { $0.status == .resolved }.count
        paragraph(
            tn("%d code(s) in this map", report.outcomes.count) + " · " + tn("%d understood", resolved),
            tone: theme.strong
        )
        y += 1
        if !recovered {
            paragraph(t("Nothing to save: this map carries no look to take."), tone: theme.text)
        }
        let rest = remainder
        if !rest.isEmpty {
            paragraph(
                tn(
                    "%d code(s) left alone — no rule of ours is aimed at them, so the map goes on drawing them as it did:",
                    rest.count
                ),
                tone: theme.text
            )
            // Only as many rows as fit, with a count of the rest.
            let shown = rest.prefix(max(0, rect.maxY - y - 2))
            for o in shown {
                drawLeftAlone(o, into: s, rect: rect, y: y, theme: theme)
                y += 1
            }
            if shown.count < rest.count, y < rect.maxY {
                s.text(
                    rect.x + 2,
                    y,
                    tn("and %d more", rest.count - shown.count),
                    Style(fg: theme.dim, bg: theme.appBg)
                )
                y += 1
            }
            y += 1
        }
        if let message, y < rect.maxY {
            s.text(rect.x, y, truncate(message, to: rect.w), Style(fg: theme.ok, bg: theme.appBg))
        }
    }

    private func drawLeftAlone(_ o: StyleRecovery.Outcome, into s: Surface, rect: Rect, y: Int, theme: Theme) {
        let code = String(format: "%@ 0x%04x", String(o.kind.rawValue), o.type)
        let what = o.meaning.isEmpty ? t("nothing identified") : o.meaning
        let column = min(
            Self.reasonColumn.upperBound,
            max(Self.reasonColumn.lowerBound, (rect.w - Self.codeColumn) / 3)
        )
        s.text(rect.x + 2, y, code, Style(fg: theme.dim, bg: theme.appBg))
        s.text(
            rect.x + Self.codeColumn,
            y,
            reason(o.status),
            Style(fg: theme.faint, bg: theme.appBg),
            limit: column - 1
        )
        s.text(
            rect.x + Self.codeColumn + column,
            y,
            truncate(what, to: max(0, rect.maxX - rect.x - Self.codeColumn - column)),
            Style(fg: theme.faint, bg: theme.appBg)
        )
    }

    /// The codes nothing was written for, worst first.
    private var remainder: [StyleRecovery.Outcome] {
        func rank(_ status: StyleRecovery.Status) -> Int {
            switch status {
            case .mixed: return 0
            case .noRule: return 1
            default: return 2
            }
        }
        return
            (report?.outcomes.values.filter {
                $0.status == .mixed || $0.status == .noRule || $0.status == .singleWitness
            } ?? []).sorted { (rank($0.status), $1.witnesses) < (rank($1.status), $0.witnesses) }
    }

    private func reason(_ status: StyleRecovery.Status) -> String {
        switch status {
        case .mixed: return t("draws several things")
        case .noRule: return t("no rule for it")
        case .singleWitness: return t("too few sightings")
        default: return ""
        }
    }

    /// The stages a run goes through, each marked off as the progress passes it.
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
        return [
            (state(0), t("preparing the map reader")),
            (state(1), t("reading the map")),
            (state(2), ground),
            (state(3), placing),
            (state(4), t("working out what the codes mean"))
        ]
    }
}
