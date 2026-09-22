import Foundation

/// `kmap osm-scan`: what an extract holds. With `--load`, the road network is loaded and
/// the repair pass rehearsed instead, which is the probe for the road-end repair.
extension CLI {
    static func osmScan(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["dump"])
        guard let path = flags.positionals.first else {
            return CLIOutput.refuse("usage: kmap osm-scan <file.osm.pbf>")
        }
        if flags.has("load") { return roadRepairProbe(path, dump: flags.value("dump")) }

        let started = Date()
        var census = OSMCensus()
        do {
            try PBFReader(url: URL(fileURLWithPath: path)).read(into: &census)
        } catch {
            return CLIOutput.failure("cannot read \(path): \(error)")
        }
        let seconds = Date().timeIntervalSince(started)
        CLILog.line("nodes:         \(census.nodes)")
        CLILog.line("ways:          \(census.ways)")
        CLILog.line("routable ways: \(census.roads), points \(census.roadPoints)")
        CLILog.line("obstacles:     \(census.obstacles), points \(census.obstaclePoints)")
        CLILog.line("addresses:     \(census.addresses) object(s) carry addr:housenumber")
        CLILog.line(String(format: "read in %.1f s", seconds))
        CLIOutput.result([
            "nodes": .int(census.nodes), "ways": .int(census.ways),
            "addresses": .int(census.addresses),
            "routableWays": .int(census.roads),
            "routablePoints": .int(census.roadPoints),
            "obstacles": .int(census.obstacles),
            "obstaclePoints": .int(census.obstaclePoints),
            "seconds": .double(seconds)
        ])
        return 0
    }
}
