import Foundation

/// Viewfinder Panoramas elevation tiles, fetched without pyhgtmap. Tiles come in zone-wide
/// zip archives, and which zone holds which degree is stated only by the image map on the
/// coverage page, so a fetch downloads a claiming archive, unpacks every `.hgt` in it and
/// corrects the index to what it held. The index file format and location are pyhgtmap's.
enum ViewfinderDEM {
    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case noIndex(Int)
        case notCovered(String)
        case notInAnyArchive(String)
        /// An archive that should hold the tile could not be fetched or unpacked: not sea.
        case unreachable(String, String)
        /// No unpacker on this machine can open a zip.
        case cannotUnpack(String)
        /// The archive came down but would not unpack to its end: damaged, or not a zip.
        case unpackedInPart(String, Int32)

        var description: String {
            switch self {
            case .noIndex(let resolution):
                "no coverage index for view\(resolution), and the coverage map could not be read"
            case .notCovered(let area):
                "\(area) is outside every Viewfinder zone"
            case .notInAnyArchive(let area):
                "\(area) is not in any of the archives that claim to cover it"
            case .unreachable(let area, let why):
                "the archive holding \(area) could not be had: \(why)"
            case .cannotUnpack(let why):
                why
            case .unpackedInPart(let archive, let code):
                "\(archive) did not unpack whole (the unpacker said \(code))"
            }
        }
    }

    // MARK: Names, by resolution in arc-seconds: 1 or 3

    static func sourceID(_ resolution: Int) -> String { "view\(resolution)" }

    static func directoryName(_ resolution: Int) -> String { "VIEW\(resolution)" }

    static func cacheDirectory(_ resolution: Int) -> URL {
        Paths.hgtCache.appendingPathComponent(directoryName(resolution), isDirectory: true)
    }

    static func cachedTile(_ area: String, resolution: Int) -> URL {
        cacheDirectory(resolution).appendingPathComponent("\(area).hgt")
    }

    /// A `.hgt` is a bare grid of big-endian 16-bit samples, so its size is the only thing
    /// that says whether a download finished: 3601 x 3601 at 1 arc-second, 1201 x 1201 at 3.
    static func expectedSize(_ resolution: Int) -> Int64 {
        let n = Int64(HGTConversion.arcSecondsPerDegree / resolution + 1)
        return 2 * n * n
    }

    static func isComplete(_ url: URL, resolution: Int) -> Bool {
        FileTools.exists(url) && FileTools.size(of: url) == expectedSize(resolution)
    }

    // MARK: Fetching

    /// Connections an archive is downloaded over.
    private static let connections = 4

    /// Fetches 1 degree tile, keeping the other tiles its archive carried, which are
    /// usually the neighbours asked for next.
    @discardableResult
    static func fetch(
        _ area: String,
        resolution: Int,
        index: inout Index,
        downloader: Downloader,
        runner: ProcessRunner,
        log: @escaping (String) -> Void
    ) async throws -> URL {
        let destination = cachedTile(area, resolution: resolution)
        if isComplete(destination, resolution: resolution) { return destination }

        let directory = cacheDirectory(resolution)
        Paths.ensure(directory)
        SweptOnce.sweep(directory) { removeAbandonedStaging(in: $0) }
        let candidates = index.urls(for: area)
        guard !candidates.isEmpty else { throw Trouble.notCovered(area) }

        var trouble: Error?
        for zip in candidates {
            guard let url = URL(string: zip), url.scheme == "http" || url.scheme == "https" else { continue }
            let archive = directory.appendingPathComponent("download-\(UUID().uuidString.prefix(8)).zip")
            // A name no later run asks for again, so its parts are not kept to resume.
            defer {
                FileTools.removeIfPresent(archive)
                PartFiles(destination: archive).removeParts()
                FileTools.removeIfPresent(PartFiles(destination: archive).layout)
            }
            do {
                log("fetching \(url.lastPathComponent) for \(area)")
                // A name of its own for this run: no other kmap downloads to it, no lock.
                _ = try await downloader.download(url: url, to: archive, connections: connections, lockHeld: true)
                let (names, whole, code) = try await unpack(
                    archive,
                    into: directory,
                    resolution: resolution,
                    runner: runner
                )
                // Not sea: the archive that should hold the tile could not be read whole.
                if !whole { trouble = Trouble.unpackedInPart(url.lastPathComponent, code) }
                let unpacked = names.sorted()
                // A zone that is mostly sea holds fewer tiles than its rectangle claims, so
                // the index is corrected to what the archive actually carried. Only from an
                // unpack that ran to its end: one stopped by a full disk carried more.
                if whole, !unpacked.isEmpty, index.entries[zip]?.sorted() != unpacked {
                    index.entries[zip] = unpacked
                    try? index.save(to: indexFile(resolution), resolution: resolution)
                }
            } catch {
                if error is CancellationError || Task.isCancelled || downloader.wasCancelled { throw error }
                log("\(url.lastPathComponent): \(error)")
                trouble = error
                continue
            }
            if isComplete(destination, resolution: resolution) { return destination }
        }
        if let trouble { throw Trouble.unreachable(area, ErrorWords.of(trouble)) }
        throw Trouble.notInAnyArchive(area)
    }

    /// Archives, their parts and unpackings a killed fetch left, an hour old, so none
    /// another kmap is filling now goes.
    static func removeAbandonedStaging(in directory: URL, now: Date = Date()) {
        let entries =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // An archive with its parts and layout goes together, and only once none of them
        // has changed for an hour: a long download finishes some parts long before others.
        func archive(_ name: String) -> String {
            guard name.hasPrefix("download-"), let zip = name.range(of: ".zip") else { return name }
            return String(name[..<zip.upperBound])
        }
        var newest: [String: Date] = [:]
        for entry in entries where isStaging(entry.lastPathComponent) {
            let key = archive(entry.lastPathComponent)
            let changed = FileTools.modified(of: entry) ?? now
            newest[key] = max(newest[key] ?? .distantPast, changed)
        }
        for entry in entries where isStaging(entry.lastPathComponent) {
            guard let changed = newest[archive(entry.lastPathComponent)], now.timeIntervalSince(changed) > 3600 else {
                continue
            }
            FileTools.removeIfPresent(entry)
        }
    }

    /// A fetch's own archive, its parts or unpacking: never a source of tiles.
    static func isStaging(_ name: String) -> Bool {
        // As kmap names them, 8 hex digits and all: a folder of the user's on the way to the
        // cache, `unpack-2026` say, is not one.
        func mark(_ text: Substring) -> Bool { text.count == 8 && text.allSatisfy { $0.isASCII && $0.isHexDigit } }
        if name.hasPrefix("unpack-") { return mark(name.dropFirst("unpack-".count)) }
        guard name.hasPrefix("download-"), let zip = name.range(of: ".zip") else { return false }
        return mark(name[name.index(name.startIndex, offsetBy: "download-".count)..<zip.lowerBound])
    }

    /// Unpacks every `.hgt` in the archive flat: they sit in per-zone folders inside, and
    /// the rest of the pipeline expects them 1 directory deep.
    private static func unpack(
        _ archive: URL,
        into directory: URL,
        resolution: Int,
        runner: ProcessRunner
    ) async throws -> (names: [String], whole: Bool, code: Int32) {
        let staging = directory.appendingPathComponent("unpack-\(UUID().uuidString.prefix(8))")
        Paths.ensure(staging)
        defer { FileTools.removeIfPresent(staging) }
        guard let unpacker = Archive.current else {
            throw Trouble.cannotUnpack(Archive.missingNote())
        }
        // Everything is unpacked and then walked: not every unpacker can flatten paths on
        // the way out, and the tiles are not always exactly 1 folder deep.
        let unpack = unpacker.unpack(archive, into: staging)
        let ran = try await runner.run(unpack.executable, unpack.arguments, allowFailure: true) { _ in }
        // unzip says 1 for a warning, with everything unpacked.
        let whole = ran.exitCode == 0 || (unpacker.tool == .unzip && ran.exitCode == 1)
        return (land(staging, into: directory, whole: whole, resolution: resolution), whole, ran.exitCode)
    }

    /// Moves the unpacked tiles into the cache and names them. From an unpack that stopped,
    /// only full-size tiles, and none over one already cached.
    static func land(_ staging: URL, into directory: URL, whole: Bool, resolution: Int) -> [String] {
        var names: [String] = []
        for file in FileTools.allFiles(under: staging) where file.pathExtension.lowercased() == "hgt" {
            if !whole && !isComplete(file, resolution: resolution) { continue }
            let name = file.deletingPathExtension().lastPathComponent.uppercased()
            let landing = directory.appendingPathComponent("\(name).hgt")
            // Full length, yet maybe the member whose check failed.
            if !whole, FileTools.exists(landing) { continue }
            FileTools.removeIfPresent(landing)
            try? FileTools.move(file, to: landing)
            names.append(name)
        }
        return names
    }
}
