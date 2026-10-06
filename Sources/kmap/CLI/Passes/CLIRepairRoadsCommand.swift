import Foundation

/// `kmap repair-roads`: the annotate pass on its own. Road ends OSM left short of their
/// junction, barriers, descriptions and repeated venues, written to a repaired copy.
extension CLI {
    static func repairRoads(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["labels", "limit", "sources"])
        if let refused = flags.refusal(
            "repair-roads",
            knows: ["labels", "limit", "sources", "no-bridges", "drop-duplicate-descriptions", "mark-duplicate-venues"],
            positionals: 2
        ) {
            return refused
        }
        let files = flags.positionals
        guard files.count >= 2 else {
            return CLIOutput.refuse(
                "usage: kmap repair-roads <in.osm.pbf> <out.osm.pbf> [--labels ru|en]"
                    + " [--limit M] [--drop-duplicate-descriptions] [--mark-duplicate-venues]"
                    + " [--no-bridges] [--sources=<list>]"
            )
        }
        guard !URL(fileURLWithPath: files[1]).sameFile(as: URL(fileURLWithPath: files[0])) else {
            return CLIOutput.refuse("repair-roads: the output is the input — name another file")
        }
        // With --sources the ground is read as a build naming them reads it; without, from
        // COP1 alone.
        var ground = [CopernicusDEM.glo30.cacheDirectory]
        if let sources = flags.value("sources") {
            let unknown = unknownSources(in: sources)
            let chosen = CopernicusDEM.canonicalSourceList(sources).split(separator: ",").map(String.init)
            guard unknown.isEmpty, !chosen.isEmpty else {
                return CLIOutput.refuse(
                    "--sources: "
                        + (unknown.isEmpty
                            ? "the list is empty" : "no source called \(unknown.joined(separator: ", "))")
                )
            }
            ground = BuildPipeline.rankedDEMDirectories(chosen: chosen)
        }
        var pass = AnnotatePass(
            source: URL(fileURLWithPath: files[0]),
            destination: URL(fileURLWithPath: files[1])
        )
        // The build's range: past it nothing more joins, and the search grid grows as its square.
        let radii = BuildOptions.repairRadiusMetres
        let limit = flags.double("limit") ?? BuildRecipe.defaultHealRadius
        guard flags.notNumbers(["limit"]).isEmpty, radii.contains(limit) else {
            return CLIOutput.refuse(
                "--limit must be metres, \(Int(radii.lowerBound)) to \(Int(radii.upperBound))"
            )
        }
        pass.repairRadius = limit
        pass.bridgeObstacles = !flags.has("no-bridges")
        pass.language = flags.value("labels") ?? pass.language
        pass.dropDuplicateDescriptions = flags.has("drop-duplicate-descriptions")
        pass.markDuplicateVenues = flags.has("mark-duplicate-venues")
        pass.dem = ground

        let started = Date()
        do {
            let tally = try pass.run { note in CLILog.line(note) }
            let seconds = Date().timeIntervalSince(started)
            CLILog.line(
                "blocks copied \(tally.copied), rebuilt \(tally.rebuilt);"
                    + " added \(tally.addedNodes) node(s) and \(tally.addedWays) link(s)"
            )
            CLILog.line(String(format: "done in %.1f s", seconds))
            CLIOutput.result([
                "out": .string(files[1]),
                "blocksCopied": .int(tally.copied),
                "blocksRebuilt": .int(tally.rebuilt),
                "addedNodes": .int(tally.addedNodes),
                "addedWays": .int(tally.addedWays),
                "seconds": .double(seconds)
            ])
            return 0
        } catch {
            return CLIOutput.failure("repair failed: \(CLIOutput.said(error))")
        }
    }
}
