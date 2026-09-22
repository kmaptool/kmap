import Foundation

/// `kmap repair-roads`: the annotate pass on its own. Road ends OSM left short of their
/// junction, barriers, descriptions and repeated venues, written to a repaired copy.
extension CLI {
    static func repairRoads(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["labels", "limit"])
        let files = flags.positionals
        guard files.count >= 2 else {
            return CLIOutput.refuse(
                "usage: kmap repair-roads <in.osm.pbf> <out.osm.pbf> [--labels ru|en]"
                    + " [--limit M] [--drop-duplicate-descriptions] [--mark-duplicate-venues]"
                    + " [--no-bridges]"
            )
        }
        var pass = AnnotatePass(
            source: URL(fileURLWithPath: files[0]),
            destination: URL(fileURLWithPath: files[1])
        )
        pass.repairRadius = flags.double("limit") ?? BuildRecipe.defaultHealRadius
        pass.bridgeObstacles = !flags.has("no-bridges")
        pass.language = flags.value("labels") ?? pass.language
        pass.dropDuplicateDescriptions = flags.has("drop-duplicate-descriptions")
        pass.markDuplicateVenues = flags.has("mark-duplicate-venues")
        pass.dem = CopernicusDEM.cacheDirectory

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
            return CLIOutput.failure("repair failed: \(error)")
        }
    }
}
