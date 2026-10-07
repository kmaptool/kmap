import Foundation

/// Deletes only kmap's own files, by name and place: a cache may be a link, a junction or a
/// disk of the person's. No folder goes whole but kmap's staging.
enum CacheClearing {
    /// Held shared by every build and alone by a clear, so neither starts under the other.
    static func inUseLock(elevation: Bool) -> URL {
        Paths.locks.appendingPathComponent(elevation ? "elevation-in-use.lock" : "extracts-in-use.lock")
    }

    // MARK: What is kmap's

    /// The elevation cache's source folders: each tiled source's, Viewfinder's, and those
    /// pyhgtmap fills for SRTM and ALOS.
    static var sourceFolders: [String] {
        DEMSources.all.map(\.directoryName) + viewfinderFolders + ["SRTM1", "SRTM3", "ALOS1", "ALOS3"]
    }

    private static var viewfinderFolders: [String] { [1, 3].map(ViewfinderDEM.directoryName) }

    /// Whether kmap writes a file or folder of that name into a folder of that kind:
    ///  - the elevation cache's top: an index;
    ///  - a source folder: a tile, the GeoTIFF it is made from, its sea and absence marks,
    ///    a part still coming; Viewfinder's also an archive being fetched and its unpacking;
    ///  - GeoTIFFs: one, or one still being fetched with its parts and layout;
    ///  - chunks: a GEDTM30 one, or its parts and layout;
    ///  - extracts: one, with its parts, layout, stamp and the copy set aside as suspect.
    static func isOwn(_ name: String, in kind: CacheFolderKind) -> Bool {
        switch kind {
        case .elevationTop:
            let indexes = [1, 3].map(ViewfinderDEM.indexFile).map(\.lastPathComponent)
            return indexes.contains(name) || (name.hasPrefix("hgtIndex_") && name.hasSuffix(".txt"))
        case .source, .viewfinder:
            if kind == .viewfinder && ViewfinderDEM.isOwnStagingName(name) { return true }
            guard let rest = afterCell(name) else { return false }
            if rest == ".hgt" || rest == ".tif" { return true }
            if rest.hasPrefix(".hgt.") && rest.hasSuffix(".part") { return true }
            return rest.hasPrefix(".") && (rest.hasSuffix(".sea") || rest.hasSuffix(".out"))
        case .tifs:
            guard let rest = afterCell(name) else { return false }
            return rest == ".tif" || isDownload(rest, of: ".assembling")
        case .chunks:
            return GEDTM30.isChunkName(name)
        case .extracts:
            guard !name.hasPrefix("."), let at = name.range(of: ".osm.pbf"), at.lowerBound > name.startIndex else {
                return false
            }
            let rest = name[at.upperBound...]
            guard rest.isEmpty || rest.hasPrefix(".") else { return false }
            return rest.split(separator: ".", omittingEmptySubsequences: false).dropFirst().allSatisfy {
                ["stamp", "layout", "suspect", "new"].contains($0) || isPart($0)
            }
        }
    }

    /// What follows a cell name, `N54E019`, as HGTName writes it; nil where none leads.
    private static func afterCell(_ name: String) -> Substring? {
        let cell = String(name.prefix(HGTName.length))
        guard name.count > cell.count, let corner = HGTName.corner(of: cell),
            HGTName.of(lat: corner.lat, lon: corner.lon) == cell
        else { return nil }
        return name.dropFirst(cell.count)
    }

    /// `<suffix>`, or a download of it under way.
    private static func isDownload(_ rest: Substring, of suffix: String) -> Bool {
        rest.hasPrefix(suffix) && PartFiles.isDownloadTail(rest.dropFirst(suffix.count))
    }

    private static func isPart(_ text: Substring) -> Bool {
        text.hasPrefix("part") && PartFiles.isDownloadTail("." + text) && text != "layout"
    }

    // MARK: Where it lies

    private static func contents(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// The folders a clear empties, resolved, each once: the cache, its source folders and the
    /// downloads beside it. One leading back to the cache, or above it, is left.
    static func folders(_ cache: URL, elevation: Bool) -> [(folder: URL, kind: CacheFolderKind, name: String)] {
        let root = FileTools.resolvingLinks(cache)
        guard elevation else { return [(root, .extracts, cache.lastPathComponent)] }
        var out: [(folder: URL, kind: CacheFolderKind, name: String)] = [(root, .elevationTop, cache.lastPathComponent)]
        // Asked of the file system by name: a disk that ignores case answers for "cop1" too.
        let beside = cache.deletingLastPathComponent()
        let named =
            sourceFolders.map {
                (
                    cache.appendingPathComponent($0),
                    viewfinderFolders.contains($0) ? CacheFolderKind.viewfinder : .source
                )
            }
            + DEMSources.tiled.map { (beside.appendingPathComponent($0.tifCacheName), CacheFolderKind.tifs) }
            + [(beside.appendingPathComponent(GEDTM30.v12.chunkDirectory.lastPathComponent), CacheFolderKind.chunks)]
        for (entry, kind) in named {
            let folder = FileTools.resolvingLinks(entry)
            let holder = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            guard FileTools.isDirectory(folder), folder.path != root.path, !root.path.hasPrefix(holder),
                !out.contains(where: { $0.folder.path == folder.path })
            else { continue }
            out.append((folder, kind, entry.lastPathComponent))
        }
        return out
    }

    /// kmap's own entries in a folder: files, and unpackings that are kmap's folders. A bare
    /// extract needs its stamp, or a region's name from the Geofabrik index at `index`: a
    /// build reads and replaces that file as its own.
    static func ownEntries(in folder: URL, kind: CacheFolderKind, index: URL = Paths.indexCache) -> [URL] {
        let inside = contents(folder)
        let names = Set(inside.map(\.lastPathComponent))
        return inside.filter { entry in
            let name = entry.lastPathComponent
            guard isOwn(name, in: kind) else { return false }
            if kind == .extracts && name.hasSuffix(".osm.pbf") && !names.contains(name + ".stamp")
                && !regionExtractNames(index: index).contains(name)
            {
                return false
            }
            if kind == .viewfinder && ViewfinderDEM.isOwnStagingName(name) {
                return ViewfinderDEM.isOwnStaging(entry, in: folder)
            }
            return FileTools.isRegularFile(entry)
        }
    }

    private static func entries(_ cache: URL, elevation: Bool, index: URL) -> [URL] {
        folders(cache, elevation: elevation).flatMap { ownEntries(in: $0.folder, kind: $0.kind, index: index) }
    }

    /// The names kmap gives the extracts of the regions in the Geofabrik index at `index`,
    /// read again only when the index changes.
    static func regionExtractNames(index: URL) -> Set<String> {
        let modified = FileTools.modified(of: index)
        if let held = extractNames.withLock({ $0[index.path] }), held.modified == modified { return held.names }
        let regions = (try? Data(contentsOf: index)).flatMap { try? RegionIndex.tables(from: $0).regions } ?? [:]
        let names = Set(regions.keys.map { Paths.cachedExtract(forRegion: $0).lastPathComponent })
        extractNames.withLock { $0[index.path] = (modified, names) }
        return names
    }

    private static let extractNames = Locked([String: (modified: Date?, names: Set<String>)]())

    /// Tiles, or extracts, among the entries, and the bytes of all of them.
    static func tally(_ entries: [URL], elevation: Bool) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for entry in entries {
            if FileTools.isDirectoryItself(entry) {
                bytes += FileTools.allFiles(under: entry, hidden: true).reduce(Int64(0)) { $0 + FileTools.size(of: $1) }
                continue
            }
            if elevation ? entry.pathExtension == "hgt" : entry.lastPathComponent.hasSuffix(".osm.pbf") { files += 1 }
            bytes += FileTools.size(of: entry)
        }
        return (files, bytes)
    }

    /// The source folders of the elevation cache holding a tile, by name.
    static func sourcesHoldingTiles(_ cache: URL) -> [String] {
        folders(cache, elevation: true).filter { source in
            guard source.kind == .source || source.kind == .viewfinder else { return false }
            return contents(source.folder).contains {
                $0.pathExtension == "hgt" && isOwn($0.lastPathComponent, in: source.kind) && FileTools.isRegularFile($0)
            }
        }.map(\.name).sorted()
    }

    /// What a clear would delete, and whether anything at all: a mark may weigh 0.
    static func preview(
        _ cache: URL,
        elevation: Bool,
        index: URL = Paths.indexCache
    ) -> (files: Int, bytes: Int64, any: Bool) {
        let found = entries(cache, elevation: elevation, index: index)
        let counted = tally(found, elevation: elevation)
        return (counted.files, counted.bytes, !found.isEmpty)
    }

    // MARK: Clearing

    /// Deletes kmap's own files. Returns what went: a file that would not go is not counted.
    static func clear(_ cache: URL, elevation: Bool, index: URL = Paths.indexCache) -> (files: Int, bytes: Int64) {
        let found = entries(cache, elevation: elevation, index: index)
        let before = tally(found, elevation: elevation)
        for entry in found { FileTools.removeIfPresent(entry) }
        let after = tally(found.filter(FileTools.exists), elevation: elevation)
        return (before.files - after.files, before.bytes - after.bytes)
    }
}
