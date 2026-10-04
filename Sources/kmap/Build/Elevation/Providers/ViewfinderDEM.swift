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
        /// No unpacker on this machine can open a zip.
        case cannotUnpack(String)

        var description: String {
            switch self {
            case .noIndex(let resolution):
                "no coverage index for view\(resolution), and the coverage map could not be read"
            case .notCovered(let area):
                "\(area) is outside every Viewfinder zone"
            case .notInAnyArchive(let area):
                "\(area) is not in any of the archives that claim to cover it"
            case .cannotUnpack(let why):
                why
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
        let candidates = index.urls(for: area)
        guard !candidates.isEmpty else { throw Trouble.notCovered(area) }

        for zip in candidates {
            guard let url = URL(string: zip), url.scheme == "http" || url.scheme == "https" else { continue }
            let archive = directory.appendingPathComponent("download-\(UUID().uuidString.prefix(8)).zip")
            defer { FileTools.removeIfPresent(archive) }
            do {
                log("fetching \(url.lastPathComponent) for \(area)")
                _ = try await downloader.download(url: url, to: archive, connections: connections)
                let unpacked = try await unpack(archive, into: directory, runner: runner).sorted()
                // A zone that is mostly sea holds fewer tiles than its rectangle claims, so
                // the index is corrected to what the archive actually carried.
                if index.entries[zip]?.sorted() != unpacked {
                    index.entries[zip] = unpacked
                    try? index.save(to: indexFile(resolution), resolution: resolution)
                }
            } catch {
                log("\(url.lastPathComponent): \(error)")
                continue
            }
            if isComplete(destination, resolution: resolution) { return destination }
        }
        throw Trouble.notInAnyArchive(area)
    }

    /// Unpacks every `.hgt` in the archive flat: they sit in per-zone folders inside, and
    /// the rest of the pipeline expects them 1 directory deep.
    private static func unpack(
        _ archive: URL,
        into directory: URL,
        runner: ProcessRunner
    ) async throws -> [String] {
        let staging = directory.appendingPathComponent("unpack-\(UUID().uuidString.prefix(8))")
        Paths.ensure(staging)
        defer { FileTools.removeIfPresent(staging) }
        guard let unpacker = Archive.current else {
            throw Trouble.cannotUnpack(Archive.missingNote())
        }
        // Everything is unpacked and then walked: not every unpacker can flatten paths on
        // the way out, and the tiles are not always exactly 1 folder deep.
        let unpack = unpacker.unpack(archive, into: staging)
        _ = try await runner.run(unpack.executable, unpack.arguments, allowFailure: true) { _ in }
        var names: [String] = []
        for file in FileTools.allFiles(under: staging) where file.pathExtension.lowercased() == "hgt" {
            let name = file.deletingPathExtension().lastPathComponent.uppercased()
            let landing = directory.appendingPathComponent("\(name).hgt")
            FileTools.removeIfPresent(landing)
            try? FileTools.move(file, to: landing)
            names.append(name)
        }
        return names
    }
}
