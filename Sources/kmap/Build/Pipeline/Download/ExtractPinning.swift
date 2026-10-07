import Foundation

/// The extracts a build reads, held in its work folder: another kmap may move a newer
/// copy into the cache meanwhile, and the splitter, which opens its input once a pass,
/// would read 2 files as 1.
extension BuildPipeline {
    /// Where this build's hold on an extract is.
    func pinnedExtract(_ cached: URL) -> URL {
        workDirectory.appendingPathComponent("extracts", isDirectory: true).appendingPathComponent(
            cached.lastPathComponent
        )
    }

    /// Each extract hard-linked into the work folder, under its own name; the cached path
    /// where a link cannot be made, across volumes or on a file system without links.
    func pinning(_ extracts: [URL]) -> [URL] {
        extracts.map { cached in
            let pinned = pinnedExtract(cached)
            FileTools.removeIfPresent(pinned)
            Paths.ensure(pinned.deletingLastPathComponent())
            guard FileTools.hardLink(cached, at: pinned) else { return cached }
            return pinned
        }
    }

    /// Lets the held copies go once the build is over: kept, they would keep an extract
    /// the cache has since replaced on disk, and count in the work folder's size.
    func unpinExtracts() {
        FileTools.removeIfPresent(workDirectory.appendingPathComponent("extracts", isDirectory: true))
    }
}
