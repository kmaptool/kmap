import Foundation

/// `kmap osm-scan --load`: the road network loaded, the loose ends found and judged, and
/// each step timed. Writes the planner's trace where `--dump` names a file.
extension CLI {
    static func roadRepairProbe(_ path: String, dump: String?) -> Int32 {
        let radius = BuildRecipe.defaultHealRadius
        do {
            let started = Date()
            let network = try RoadNetworkLoader(url: URL(fileURLWithPath: path)).load()
            let loadSeconds = Date().timeIntervalSince(started)
            CLILog.line("routable ways: \(network.wayCount), points \(network.refs.count)")
            CLILog.line("obstacles:     \(network.obstacleCount), points \(network.obstacleLat.count)")
            CLILog.line(String(format: "loaded in %.1f s", loadSeconds))

            let scanning = Date()
            let (found, loose) = RoadRepair(network: network, limit: radius).candidates()
            let scanSeconds = Date().timeIntervalSince(scanning)
            CLILog.line("road ends within \(radius) m of another line: \(found.count)")
            CLILog.line(String(format: "scanned in %.1f s", scanSeconds))

            let judging = Date()
            let hgt = CopernicusDEM.cacheDirectory
            let terrain = FileManager.default.fileExists(atPath: hgt.path) ? Terrain(directory: hgt) : nil
            let plan = RepairPlanner(network: network, terrain: terrain, bridging: true, limit: radius)
                .plan(found, loose: loose)
            let inserts = plan.inserts.values.reduce(0) { $0 + $1.count }
            let judgeSeconds = Date().timeIntervalSince(judging)
            // Commonest first, then by name: this list is compared between runs.
            for (reason, count) in plan.counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
                CLILog.line("  \(reason): \(count)")
            }
            CLILog.line(
                "  moves \(plan.moves.count), merges \(plan.merges.count), "
                    + "inserts \(inserts), bridges \(plan.bridges.count)"
            )
            CLILog.line(String(format: "judged in %.1f s", judgeSeconds))
            if let dump {
                try? plan.trace.sorted().joined(separator: "\n")
                    .write(toFile: dump, atomically: true, encoding: .utf8)
            }
            CLIOutput.result([
                "routableWays": .int(network.wayCount),
                "routablePoints": .int(network.refs.count),
                "obstacles": .int(network.obstacleCount),
                "obstaclePoints": .int(network.obstacleLat.count),
                "candidates": .int(found.count),
                "verdicts": .object(plan.counts.mapValues { .int($0) }),
                "moves": .int(plan.moves.count),
                "merges": .int(plan.merges.count),
                "inserts": .int(inserts),
                "bridges": .int(plan.bridges.count),
                "seconds": [
                    "load": .double(loadSeconds), "scan": .double(scanSeconds),
                    "judge": .double(judgeSeconds)
                ]
            ])
            return 0
        } catch {
            return CLIOutput.failure("cannot read \(path): \(error)")
        }
    }
}
