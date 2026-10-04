import Foundation

/// A build watched to the end: the log streamed as it arrives, each stage transition
/// reported once, and the exit code the run earned. The same loop feeds both shapes of
/// output; progress is reported when it has visibly moved.
extension CLI {
    /// How often the pipeline is polled for news.
    private static let followPollNanoseconds: UInt64 = 250_000_000

    static func follow(_ pipeline: BuildPipeline, landingIn destination: URL) async -> Int32 {
        var printer = LogPrinter()
        var lastStatus: [String: BuildPipeline.StageStatus] = [:]
        var gate = ProgressGate()
        /// Stages whose heading is printed: one that began and ended between 2 polls is
        /// never seen running.
        var headed = Set<String>()
        var lastPoll = Date.distantPast
        while true {
            let snapshot = pipeline.snapshot()
            // A held stage is reported as not started: it is announced when it sets to work.
            var changed: [(stage: BuildPipeline.Stage, status: BuildPipeline.StageStatus, detail: String)] = []
            var headings: [(at: Date, text: String)] = []
            for stage in snapshot.stages {
                let shown = stage.shown(among: snapshot.stages)
                guard lastStatus[stage.id.rawValue] != shown.status else { continue }
                lastStatus[stage.id.rawValue] = shown.status
                changed.append((stage, shown.status, shown.detail))
                let worked = shown.status == .running || shown.status == .done || shown.status == .failed
                if worked, headed.insert(stage.id.rawValue).inserted {
                    // Where it began; a stage let go after being held begins with this poll.
                    headings.append((max(stage.startedAt ?? lastPoll, lastPoll), "── \(stage.id.title)"))
                }
            }
            lastPoll = Date()
            printer.drain(pipeline.log, headings: headings)
            for (stage, status, detail) in changed {
                CLIOutput.stage(stage.id.rawValue, status.rawValue, title: stage.id.title, detail: detail)
            }

            if CLIOutput.isJSON {
                for stage in snapshot.stages where stage.shown(among: snapshot.stages).status == .running {
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
        if snapshot.cancelled {
            CLILog.line("\ncancelled")
            CLIOutput.result(["cancelled": .bool(true)])
            return CLIOutput.Exit.cancelled
        }
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
