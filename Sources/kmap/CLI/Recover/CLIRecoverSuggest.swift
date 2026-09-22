import Foundation

/// What to do when no downloaded OSM data matches the map: name the candidate downloads
/// rather than fetching them.
extension CLI {
    /// Most regions suggested; any one of them is ground enough.
    private static let mostSuggested = 6
    private static let bytesPerMB = 1_048_576.0

    static func suggestExtracts(for frame: BBox, path: String) async -> Int32 {
        CLILog.error("recover: no downloaded OSM data matches \(frame.display)")
        let index = RegionIndex()
        guard (try? await index.load()) != nil else { return 1 }
        let wanted = RegionSuggestion.suggestedRegions(
            on: RegionSuggestion.drawnGround(of: Paths.expand(path)),
            index: index
        ).prefix(mostSuggested)
        guard !wanted.isEmpty else {
            return CLIOutput.failure("and no region kmap can download overlaps it either")
        }
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
        CLILog.line("\nAny one of these regions is ground enough — download with:")
        for candidate in wanted {
            CLILog.line(
                String(
                    format: "  kmap build %@  (holds %.0f%% of the map's data,"
                        + " %.1f MB of it; %.0f%% of the region is under the map)",
                    candidate.region.id,
                    candidate.share * 100,
                    candidate.drawn / bytesPerMB,
                    candidate.inside * 100
                )
            )
        }
        CLILog.line("\nor pass an extract of your own with --extract=<file.osm.pbf>")
        return 1
    }
}
