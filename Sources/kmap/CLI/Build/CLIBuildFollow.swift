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
        while true {
            printer.drain(pipeline.log)

            let snapshot = pipeline.snapshot()
            for stage in snapshot.stages where lastStatus[stage.id.rawValue] != stage.status {
                lastStatus[stage.id.rawValue] = stage.status
                if stage.status == .running { CLILog.line("── \(stage.id.title)") }
                CLIOutput.stage(
                    stage.id.rawValue,
                    stage.status.rawValue,
                    title: stage.id.title,
                    detail: stage.detail
                )
            }

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
