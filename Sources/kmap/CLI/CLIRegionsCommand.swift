import Foundation

/// `kmap regions`: the Geofabrik index, listed, searched or opened by id.
extension CLI {
    /// What `kmap regions <query>` lists.
    enum RegionListing {
        /// No query: the continents.
        case roots
        /// The query is exactly the id of a region that has sub-regions: those.
        case opened(Region)
        /// Anything else: a search across every region.
        case search(String)
    }

    /// Chooses the listing for a query. Opening by exact id comes before searching, so
    /// `kmap regions europe` walks into Europe rather than finding it; a leaf's id still
    /// searches, which finds the leaf itself.
    static func regionListing(for query: String, in index: RegionIndex)
        -> (listing: RegionListing, regions: [Region]) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return (.roots, index.children(of: nil)) }
        if let region = index.region(q) ?? index.region(q.lowercased()), region.hasChildren {
            return (.opened(region), index.children(of: region.id))
        }
        return (.search(q), index.search(q, limit: 60))
    }

    static func listRegions(query: String) async -> Int32 {
        let index = RegionIndex()
        do {
            try await index.load()
        } catch {
            return CLIOutput.failure("\(error.localizedDescription)")
        }

        let (listing, regions) = regionListing(for: query, in: index)
        var opened: Region?
        if case .opened(let region) = listing {
            opened = region
            CLILog.line("\(index.breadcrumb(region.id))\n")
        }
        // Wide enough for the longest id on show, and never narrower than the id itself.
        // `padding(toLength:)` truncates as readily as it pads, and at a fixed 34 the one
        // id longer than that - saint-helena-ascension-and-tristan-da-cunha - came out
        // cut in half and touching the name, which is the id somebody would then copy
        // into `kmap build` and be told does not exist.
        let idColumn = max(regions.map(\.id.count).max() ?? 0, 8)
        for region in regions {
            let mark = region.pbfURL == nil ? "  " : "· "
            let children = region.hasChildren ? "  (\(region.childIDs.count) sub-regions)" : ""
            let id = region.id + String(repeating: " ", count: idColumn - region.id.count)
            CLILog.line("\(mark)\(id)  \(region.name)\(children)")
            // A single search hit is described in full. Two boxes mean the region
            // crosses 180 deg.
            guard case .search = listing, regions.count == 1 else { continue }
            for box in region.boxes {
                CLILog.line("    \(box.display)   \(box.demTileCount) cell(s)")
            }
            if region.boxes.count > 1 {
                CLILog.line("    \(region.demTileCount) cell(s) in all — the box around both"
                      + " would be \(region.bbox.demTileCount)")
            }
        }
        // A search that matched nothing said nothing at all and exited 0, which reads
        // exactly like a search that worked. Every other command answers.
        if regions.isEmpty, case .search(let query) = listing {
            CLILog.line(t("nothing here answers to \"%@\"", query))
            CLIOutput.result(["in": .null, "regions": .array([])])
            return 1
        }
        if regions.contains(where: \.hasChildren) {
            CLILog.line("\nOpen a region with sub-regions:  kmap regions <id>")
        }
        if regions.contains(where: { $0.pbfURL != nil }) {
            CLILog.line("Build one:  kmap build <id>")
        }
        CLIOutput.result([
            "in": .of(opened?.id),
            "regions": .array(regions.map { region in
                ["id": .string(region.id), "name": .string(region.name),
                 "parent": .of(region.parentID),
                 "downloadable": .bool(region.pbfURL != nil),
                 "subRegions": .int(region.childIDs.count),
                 "demCells": .int(region.demTileCount),
                 "boxes": .array(region.boxes.map {
                     ["minLat": .double($0.minLat), "minLon": .double($0.minLon),
                      "maxLat": .double($0.maxLat), "maxLon": .double($0.maxLon)]
                 })]
            }),
        ])
        return 0
    }
}
