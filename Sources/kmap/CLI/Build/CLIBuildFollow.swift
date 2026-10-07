import Foundation

/// A build watched to the end: the log streamed as it arrives, each stage transition
/// reported once, and the exit code the run earned. The same loop feeds both shapes of
/// output; progress is reported when it has visibly moved.
extension CLI {
    /// How often the pipeline is polled for news.
    private static let followPollNanoseconds: UInt64 = 250_000_000

    /// The status JSON reports for a stage, nil for none: the stage as it is, never back to
    /// not started, so a reader is never told a stage it saw at work has not started. A
    /// stage that runs again, as a re-split does, is reported running again. A build that
    /// stopped puts a stage it held back to not started: that one ends `failed`.
    static func reported(
        _ status: BuildPipeline.StageStatus,
        after last: BuildPipeline.StageStatus?,
        ended: Bool
    ) -> BuildPipeline.StageStatus? {
        guard let last else { return status }
        guard status != last else { return nil }
        if status == .pending { return ended && last == .running ? .failed : nil }
        return status
    }

    /// Whether the text heads a stage at this poll: when it is first seen at work, by its
    /// real status, and again when it runs anew after it ended or was put back, as a
    /// re-split or a fresh download of a damaged extract does.
    static func heads(
        _ status: BuildPipeline.StageStatus,
        seen last: BuildPipeline.StageStatus?,
        before: Bool
    ) -> Bool {
        guard status == .running || status == .done || status == .failed else { return false }
        return !before || (status == .running && last != .running)
    }

    /// What the stages say at each poll: headings for the text and events for the stream,
    /// each dated when it happened, so they stand among the log lines in their order.
    struct StageNews {
        /// The status each stage was last reported with in JSON. A stage seen only once it
        /// had ended is reported running first, as it was.
        private var lastReported: [String: BuildPipeline.StageStatus] = [:]
        /// Stages whose heading is printed: one that began and ended between 2 polls is
        /// never seen running.
        private var headed = Set<String>()
        /// The status each stage had at the last poll, so a stage that runs anew is headed
        /// anew.
        private var lastSeen: [String: BuildPipeline.StageStatus] = [:]
        private var lastPoll = Date.distantPast

        /// The marks of the stages as read at `polled`.
        mutating func marks(
            _ stages: [BuildPipeline.Stage],
            ended: Bool,
            stopped: String,
            polled: Date
        ) -> [(at: Date, mark: LogPrinter.Item)] {
            var marks: [(at: Date, mark: LogPrinter.Item)] = []
            for stage in stages {
                let id = stage.id.rawValue
                let heading = heads(stage.status, seen: lastSeen[id], before: headed.contains(id))
                let status = reported(stage.status, after: lastReported[id], ended: ended)
                // Dated no earlier than the last poll: what came before it is printed.
                let began = max(stage.startedAt ?? lastPoll, lastPoll)
                var at = began
                if stage.status == .done || stage.status == .failed, let started = stage.startedAt {
                    at = max(started.addingTimeInterval(stage.seconds), lastPoll)
                }
                lastSeen[id] = stage.status
                if heading {
                    headed.insert(id)
                    marks.append((began, .heading("── \(stage.id.title)")))
                }
                if let status {
                    // Begun and ended between 2 polls: its running goes out first, dated when
                    // it began, so a reader of the stream never sees a stage skip the step.
                    if status == .done || status == .failed, lastReported[id] != .running,
                        let started = stage.startedAt
                    {
                        marks.append((max(started, lastPoll), .stage(stage.id, .running, detail: "")))
                    }
                    lastReported[id] = status
                    marks.append(
                        (at, .stage(stage.id, status, detail: status == stage.status ? stage.detail : stopped))
                    )
                }
            }
            lastPoll = polled
            return marks
        }
    }

    static func follow(_ pipeline: BuildPipeline, landingIn destination: URL) async -> Int32 {
        var printer = LogPrinter()
        var news = StageNews()
        var gate = ProgressGate()
        while true {
            // The log's count taken before the stages, its lines after them: a line printed
            // now was written before this look at the stages. One written after waits for
            // the next poll; so does the change it precedes, but for the moment between the
            // 2 reads.
            let polled = Date()
            let last = pipeline.log.lastSeq
            let snapshot = pipeline.snapshot()
            let lines = pipeline.log.snapshot()
            let marks = news.marks(
                snapshot.stages,
                ended: snapshot.finished,
                stopped: snapshot.cancelled ? t("cancelled") : t("failed"),
                polled: polled
            )
            // Once the run is seen finished, nothing it says is still to come.
            printer.drain(lines, marks: marks, through: snapshot.finished ? .max : last)

            if CLIOutput.isJSON {
                for stage in snapshot.stages where stage.status == .running {
                    guard
                        gate.speaks(
                            stage: stage.id.rawValue,
                            fraction: stage.fraction,
                            overall: snapshot.overall,
                            detail: stage.detail
                        )
                    else { continue }
                    CLIOutput.progress(
                        stage: stage.id.rawValue,
                        fraction: stage.fraction,
                        overall: snapshot.overall,
                        detail: stage.detail
                    )
                }
            }

            if snapshot.finished { return finished(snapshot, landingIn: destination) }
            try? await Task.sleep(nanoseconds: followPollNanoseconds)
        }
    }

    /// The last word: the failure, the cancellation, or the files that came out.
    private static func finished(_ snapshot: BuildPipeline.Snapshot, landingIn destination: URL) -> Int32 {
        if let failure = snapshot.failure {
            return CLIOutput.failure("\nfailed: \(failure)")
        }
        if snapshot.cancelled { return CLIOutput.cancelled() }
        CLILog.line("")
        for output in snapshot.outputs {
            CLILog.line("\(output.name)  \(Fmt.bytes(output.size))")
        }
        CLILog.line(Paths.display(destination))
        // The stream's progress always closes at 1, so a parser can drive its bar to the
        // end without special-casing the result event.
        CLIOutput.progress(stage: nil, fraction: nil, overall: snapshot.overall)
        CLIOutput.result([
            "destination": .string(destination.path),
            "outputs": .array(
                snapshot.outputs.map {
                    [
                        "name": .string($0.name), "path": .string($0.url.path),
                        "bytes": .int(Int($0.size))
                    ]
                }
            ),
            "stages": .array(
                snapshot.stages.map { stage in
                    [
                        "id": .string(stage.id.rawValue),
                        "title": .string(stage.id.title),
                        "status": .string(stage.status.rawValue),
                        "seconds": .double(stage.seconds),
                        "peakBytes": .int(Int(stage.peakBytes))
                    ]
                }
            ),
            "seconds": .double((snapshot.finishedAt ?? Date()).timeIntervalSince(snapshot.startedAt))
        ])
        return 0
    }
}
