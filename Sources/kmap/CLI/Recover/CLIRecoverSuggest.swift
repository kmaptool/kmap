import Foundation

/// What to do when no downloaded OSM data matches the map: name the candidate downloads
/// rather than fetching them.
extension CLI {
    /// Most regions suggested, the one holding most of the map's data first.
    private static let mostSuggested = 6
    private static let bytesPerMB = 1_048_576.0

    /// What is said where no region is left to suggest. `held`: the regions holding some
    /// of the map are all in the cache, and were read to no avail.
    static func nothingToSuggest(held: Bool) -> String {
        held
            ? "and the extracts kmap holds around this map do not cover what it draws"
                + " - pass the extract of the region the map shows with --extract"
            : "and no region kmap can download overlaps it either"
    }

    static func suggestExtracts(for frame: BBox, path: String, why: String? = nil) async -> Int32 {
        CLILog.error("recover: \(why ?? "no downloaded OSM data matches \(frame.display)")")
        let index = RegionIndex()
        do {
            try await index.load()
        } catch {
            if Task.isCancelled { return CLIOutput.cancelled() }
            CLILog.line("pass an extract of the map's region with --extract=<file.osm.pbf>")
            return CLIOutput.failure("the list of downloadable regions did not load: \(CLIOutput.said(error))")
        }
        let drawn = RegionSuggestion.drawnGround(of: Paths.expand(path))
        // The regions recover would read, then any other holding some of the map.
        var listed: Set<String> = []
        let holding =
            RegionSuggestion.groundToRead(for: drawn, index: index)
            + RegionSuggestion.groundToName(for: drawn, index: index)
        let wanted =
            holding
            .filter { !RegionSuggestion.isCached($0.region) && listed.insert($0.region.id).inserted }
            .prefix(mostSuggested)
        guard !wanted.isEmpty else { return CLIOutput.failure(nothingToSuggest(held: !holding.isEmpty)) }
        CLIOutput.result([
            "needsExtract": .bool(true),
            "frame": frameAsData(frame),
            "suggested": .array(
                wanted.map { candidate in
                    [
                        "region": .string(candidate.region.id),
                        "share": .double(candidate.share),
                        "drawnBytes": .double(candidate.drawn),
                        "inside": .double(candidate.inside)
                    ]
                }
            )
        ])
        CLILog.line(
            "\nRegions holding a quarter of the map's data between them are ground enough,"
                + " the one holding the most first - download with:"
        )
        for candidate in wanted {
            CLILog.line(
                String(
                    format: "  kmap build %@  (holds %.0f%% of the map's data, %.1f MB of it)",
                    candidate.region.id,
                    candidate.share * 100,
                    candidate.drawn / bytesPerMB
                )
            )
        }
        CLILog.line("\nor pass an extract of your own with --extract=<file.osm.pbf>")
        return 1
    }
}
