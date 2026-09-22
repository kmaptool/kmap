import Foundation

/// `kmap fetch-dem`: one elevation tile through kmap's own downloaders, for comparison
/// against the tile pyhgtmap fetches for the same name.
///
///     kmap fetch-dem N44E034 --source view3
extension CLI {
    private static let defaultViewfinderSource = "view3"

    static func fetchDEM(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["source"])
        guard let area = flags.positionals.first else {
            return CLIOutput.refuse("usage: kmap fetch-dem <area> [--source view1|view3]")
        }
        let source = flags.value("source") ?? defaultViewfinderSource
        guard source.hasPrefix("view"), let resolution = Int(source.dropFirst("view".count)),
            resolution == 1 || resolution == 3
        else {
            return CLIOutput.refuse("unknown source: \(source)")
        }

        let log = Log(showing: CLIOutput.showing)
        let runner = ProcessRunner()
        let downloader = Downloader(log: log)
        do {
            var index = try await ViewfinderDEM.index(resolution, downloader: downloader) { CLILog.line($0) }
            CLILog.line("index: \(index.entries.count) archive(s), \(index.urls(for: area).count) claim \(area)")
            let file = try await ViewfinderDEM.fetch(
                area,
                resolution: resolution,
                index: &index,
                downloader: downloader,
                runner: runner
            ) { CLILog.line($0) }
            CLILog.line("\(file.path)  \(FileTools.size(of: file)) bytes")
            CLIOutput.result([
                "area": .string(area), "source": .string(source),
                "file": .string(file.path),
                "bytes": .int(Int(FileTools.size(of: file))),
                "archives": .int(index.entries.count)
            ])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }
}
