import Foundation

/// `kmap make-gpi`: the Custom POI file on its own, of everything carrying a description.
extension CLI {
    static func makeGPI(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["codepage", "category", "prefer", "exclude"])
        if let refused = flags.refusal(
            "make-gpi",
            knows: ["codepage", "category", "prefer", "exclude", "show-on-map"],
            positionals: 2
        ) {
            return refused
        }
        let files = flags.positionals
        guard files.count >= 2 else {
            return CLIOutput.refuse(
                "usage: kmap make-gpi <in.osm.pbf> <out.gpi> [--codepage cp1251]"
                    + " [--category NAME] [--prefer ru] [--show-on-map] [--exclude k=v,...]"
            )
        }
        // Written over its own input, the extract would be lost to a few kilobytes of POIs.
        guard !URL(fileURLWithPath: files[1]).sameFile(as: URL(fileURLWithPath: files[0])) else {
            return CLIOutput.refuse("make-gpi: the output is the input — name another file")
        }
        var gpi = MakeGPI(
            source: URL(fileURLWithPath: files[0]),
            destination: URL(fileURLWithPath: files[1])
        )
        gpi.codepage = flags.value("codepage") ?? gpi.codepage
        guard MakeGPI.codePage(named: gpi.codepage) != nil else {
            return CLIOutput.refuse(MakeGPI.Trouble.unknownCodePage(gpi.codepage).description)
        }
        gpi.category = flags.value("category") ?? gpi.category
        gpi.prefer = flags.value("prefer") ?? gpi.prefer
        gpi.showOnMap = flags.has("show-on-map")
        gpi.exclude = flags.values("exclude")

        do {
            let report = try gpi.run()
            var notes = ["\(report.fromNodes) from nodes, \(report.fromAreas) from areas"]
            if report.uninformative > 0 { notes.append("\(report.uninformative) dropped as uninformative") }
            if report.excluded > 0 { notes.append("\(report.excluded) omitted as hidden") }
            CLILog.line(
                String(
                    format: "%d described POI(s) → %@ (%.1f kB)%@",
                    report.written,
                    gpi.destination.lastPathComponent as NSString,
                    Double(report.bytes) / 1000.0,
                    ("; " + notes.joined(separator: ", ")) as NSString
                )
            )
            CLIOutput.result([
                "out": .string(gpi.destination.path),
                "written": .int(report.written),
                "bytes": .int(report.bytes),
                "fromNodes": .int(report.fromNodes),
                "fromAreas": .int(report.fromAreas),
                "uninformative": .int(report.uninformative),
                "excluded": .int(report.excluded)
            ])
            return 0
        } catch {
            return CLIOutput.failure("\(CLIOutput.said(error))")
        }
    }
}
