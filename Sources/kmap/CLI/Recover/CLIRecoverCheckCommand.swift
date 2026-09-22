import Foundation

/// `kmap recover-check`: two maps compared tag by tag, what the original draws each
/// meaning with against what the rebuilt map draws it with. The full test of a style
/// recovery, every tag before and after.
extension CLI {
    static func recoverCheck(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["extract"])
        guard flags.positionals.count == 2 else {
            return CLIOutput.refuse("usage: kmap recover-check <original.img> <rebuilt.img> [--extract=FILE.pbf]…")
        }
        let original = Paths.expand(flags.positionals[0])
        let rebuilt = Paths.expand(flags.positionals[1])
        let extracts = flags.values("extract").map { URL(fileURLWithPath: $0) }
        let log = Log(showing: CLIOutput.showing)
        do {
            let neutral = try await neutralRules(log: log)
            defer { FileTools.removeIfPresent(neutral) }
            let theirs = try await StyleRecovery.run(
                img: original,
                extracts: extracts,
                log: log,
                rulesDirectory: neutral
            )
            let ours = try await StyleRecovery.run(img: rebuilt, extracts: extracts, log: log, rulesDirectory: neutral)
            let compared = TagComparison(
                original: theirs,
                rebuilt: ours,
                theirTyp: TagComparison.typSource(of: original),
                ourTyp: TagComparison.typSource(of: rebuilt)
            )
            printComparison(compared)
            return compared.different.isEmpty && compared.missing.isEmpty ? 0 : 1
        } catch {
            return CLIOutput.failure("recover-check: \(error.localizedDescription)")
        }
    }

    private static func printComparison(_ compared: TagComparison) {
        CLILog.line("")
        CLILog.line(
            "tags compared: \(compared.same + compared.different.count),"
                + " agreeing \(compared.same), differing \(compared.different.count),"
                + " undrawn by the rebuilt map \(compared.missing.count)"
        )
        for d in compared.different {
            CLILog.line(String(format: "  DIFF  %-40@ theirs %@  ours %@", d.tag as NSString, d.theirs, d.ours))
        }
        for m in compared.missing {
            CLILog.line(
                String(format: "  MISS  %-40@ theirs %@ ×%d, ours nothing", m.tag as NSString, m.theirs, m.count)
            )
        }
        CLIOutput.result([
            "agreeing": .int(compared.same),
            "differing": .array(
                compared.different.map {
                    ["tag": .string($0.tag), "theirs": .string($0.theirs), "ours": .string($0.ours)]
                }
            ),
            "missing": .array(
                compared.missing.map {
                    ["tag": .string($0.tag), "theirs": .string($0.theirs), "count": .int($0.count)]
                }
            )
        ])
    }
}
