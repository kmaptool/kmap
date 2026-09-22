import Foundation

/// `kmap typinfo`: what kmap can see inside a Garmin `.img`. Its sub-files, the zoom
/// ladder tile by tile, and the identity of the TYP where there is one.
extension CLI {
    /// The sub-files worth a line each: the style, the search index and the map set.
    private static let listedSubFiles: Set<String> = ["TYP", "MDR", "MPS"]

    static func typinfo(_ arguments: [String]) -> Int32 {
        let paths = Flags(arguments).positionals
        guard !paths.isEmpty else {
            return CLIOutput.refuse("typinfo needs one or more .img paths")
        }
        var maps: [JSONValue] = []
        var unreadable = 0
        for path in paths {
            let url = Paths.expand(path)
            CLILog.line(url.lastPathComponent)
            guard FileTools.exists(url) else {
                CLILog.line("  not found")
                maps.append(["file": .string(url.lastPathComponent), "found": false])
                unreadable += 1
                continue
            }
            guard ImgContainer.isImg(url) else {
                CLILog.line("  not a Garmin IMG")
                maps.append(["file": .string(url.lastPathComponent), "found": true, "isIMG": false])
                unreadable += 1
                continue
            }
            maps.append(describeImg(url))
        }
        CLIOutput.result(["maps": .array(maps)])
        // The per-file verdicts are the answer; the code says whether every file could be
        // read at all, so a script need not parse to notice a wrong path.
        return unreadable == 0 ? 0 : 1
    }

    private static func describeImg(_ url: URL) -> JSONValue {
        let directory = ImgContainer.directory(of: url)
        let listed = directory.filter { listedSubFiles.contains($0.ext.uppercased()) }
        CLILog.line("  \(directory.count) sub-file(s)")
        for sub in listed {
            CLILog.line("    \(sub.fullName)  \(Fmt.bytes(Int64(sub.size)))  \(sub.blocks.count) block(s)")
        }
        printLadders(ladders(of: url, in: directory))

        let identity = ImgContainer.typIdentity(in: url)
        if let identity {
            CLILog.line(
                "  TYP: family \(identity.familyID), product \(identity.productID),"
                    + " \(Fmt.bytes(Int64(identity.size)))"
            )
        } else if directory.contains(where: { $0.ext.uppercased() == "TYP" }) {
            CLILog.line("  TYP present but its header could not be read")
        } else {
            CLILog.line("  no TYP inside")
        }
        return [
            "file": .string(url.lastPathComponent),
            "path": .string(url.path),
            "found": true,
            "isIMG": true,
            "subFiles": .int(directory.count),
            "listed": .array(
                listed.map {
                    [
                        "name": .string($0.fullName), "bytes": .int($0.size),
                        "blocks": .int($0.blocks.count)
                    ]
                }
            ),
            "typ": identity.map {
                ["family": .int($0.familyID), "product": .int($0.productID), "bytes": .int($0.size)]
            } ?? .null
        ]
    }

    private typealias Rung = (level: Int, resolution: Int, count: Int)

    /// The zoom ladder of every tile: which levels it holds and at what resolution each
    /// draws. Two maps of the same ground can differ only here and look nothing alike
    /// when zoomed out.
    private static func ladders(of url: URL, in directory: [ImgContainer.SubFile]) -> [String: [Rung]] {
        var ladders: [String: [Rung]] = [:]
        for tre in directory where tre.ext.uppercased() == "TRE" {
            guard let data = ImgContainer.read(tre, from: url),
                let tree = try? ImgElements.Tree(data, tile: tre.name)
            else { continue }
            var seen: [Int: (shift: Int, count: Int)] = [:]
            for division in tree.subdivisions {
                seen[division.level, default: (division.shift, 0)].count += 1
            }
            ladders[tre.name] = seen.sorted { $0.key < $1.key }
                .map { (level: $0.key, resolution: GarminGrid.fullResolution - $0.value.shift, count: $0.value.count) }
        }
        return ladders
    }

    /// Distinct ladders, each with the tiles that share it: an overview submap has its
    /// own, and a detail tile that lost its finest level draws nothing of what the style
    /// puts there.
    private static func printLadders(_ ladders: [String: [Rung]]) {
        var shapes: [String: [String]] = [:]
        for (tile, ladder) in ladders {
            let shape = ladder.map { "L\($0.level)→res \($0.resolution)" }.joined(separator: ", ")
            shapes[shape, default: []].append(tile)
        }
        for (shape, tiles) in shapes.sorted(by: { $0.value.count > $1.value.count }) {
            CLILog.line("  zoom ladder ×\(tiles.count): \(shape)")
        }
        guard ladders.count > 1, let first = ladders.keys.sorted().first, let ladder = ladders[first] else {
            return
        }
        let same = ladders.values.allSatisfy { $0.map(\.resolution) == ladder.map(\.resolution) }
        let finest = ladders.values.compactMap { $0.map(\.resolution).max() }.max() ?? 0
        let coarsest = ladders.values.compactMap { $0.map(\.resolution).min() }.min() ?? 0
        CLILog.line(
            "    \(ladders.count) tile(s), "
                + (same ? "all on the same ladder" : "ladders differ")
                + " · resolutions \(coarsest)…\(finest)"
        )
    }
}
