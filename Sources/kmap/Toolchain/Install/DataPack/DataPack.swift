import Foundation

/// A pack kmap downloads whole rather than builds: the precompiled coastlines, and the
/// administrative boundaries address search reads. In one place because the installer,
/// the toolchain screen and a build all need the same facts.
struct DataPack: Equatable {
    let id: String
    let url: URL
    let file: URL
    /// What it is, in the words a build's log uses.
    let what: String

    static let sea = DataPack(
        id: "sea",
        url: URL(string: "https://www.thkukuk.de/osm/data/sea-latest.zip")!,
        file: Paths.seaData,
        what: "coastline data"
    )

    static let bounds = DataPack(
        id: "bounds",
        url: URL(string: "https://www.thkukuk.de/osm/data/bounds-latest.zip")!,
        file: Paths.boundsData,
        what: "boundary data"
    )

    static let all: [DataPack] = [sea, bounds]

    static func named(_ id: String) -> DataPack? { all.first { $0.id == id } }

    /// Below this it is the remains of a download: the smallest pack is 344 MB.
    static let smallestPack: Int64 = 1_000_000

    /// Where an update is written while it comes down, beside the pack it replaces.
    static let stagingSuffix = "new"

    /// What a build that goes without the pack loses, for its log.
    var withoutIt: String {
        switch id {
        case DataPack.sea.id: return "the coastline comes from the extract and can flood inland at low zoom"
        case DataPack.bounds.id: return "the city and region on an address are a best guess"
        default: return "the map is built without it"
        }
    }

    /// Through a link too: a pack kept on another disk is used by the build all the same.
    var isInstalled: Bool {
        let real = FileTools.resolvingLinks(file)
        return FileTools.exists(real) && FileTools.size(of: real) > Self.smallestPack
    }
}

extension DataPack {
    /// The pack the server publishes, when newer than the one here. Nil for an uninstalled
    /// pack, an unreachable server, or one that gives neither a date nor a different size:
    /// none is worth 2 GB of traffic.
    func newer(
        probe: (URL) async throws -> Downloader.RemoteInfo = {
            try await Downloader.probeRetrying($0)
        }
    ) async -> News? {
        guard isInstalled, let remote = try? await probe(url) else { return nil }
        let published = remote.lastModified.flatMap(Self.date(of:))
        let stamp = CacheStamp.read(besides: file)

        if let stamp {
            // Stamped when it was fetched: the exact question, answered exactly.
            if stamp.matches(size: remote.size, lastModified: remote.lastModified) { return nil }
        } else if let published, let here = FileTools.modified(of: FileTools.resolvingLinks(file)) {
            // Installed before kmap stamped these, so the file's own date stands in: it is
            // when the download finished, never earlier than what was published by then.
            if published <= here { return nil }
        } else if remote.size == FileTools.size(of: FileTools.resolvingLinks(file)) {
            // Nothing to compare but the size, and it agrees.
            return nil
        }
        return News(size: remote.size, lastModified: remote.lastModified, published: published)
    }

    /// Fetches the pack and puts it in place, stamped with what the server said. Written
    /// beside the one it replaces and moved over it only when whole, so an update stopped
    /// halfway leaves the old pack rather than none.
    func fetch(
        using downloader: Downloader,
        connections: Int = 4,
        lastModified: String? = nil
    ) async throws {
        let staging = file.appendingPathExtension(Self.stagingSuffix)
        // Held to the swap: another kmap updating the pack waits, and then finds it done
        // rather than fetching a gigabyte again.
        let stampFile = CacheStamp.url(for: file)
        func stampNow() -> (Data?, Date?) { (try? Data(contentsOf: stampFile), FileTools.modified(of: stampFile)) }
        let before = stampNow()
        let lock = try await downloader.holdingDownload(of: staging)
        defer { withExtendedLifetime(lock) {} }
        if let lastModified, CacheStamp.read(besides: file)?.lastModified == lastModified { return }
        // An install asks no date: one another kmap stamped while this one waited is it.
        let after = stampNow()
        if lastModified == nil, FileTools.exists(file), after.0 != nil, after.0 != before.0 || after.1 != before.1 {
            return
        }
        try await downloader.download(url: url, to: staging, connections: connections, lockHeld: true)
        var stamped = lastModified
        if stamped == nil { stamped = (try? await Downloader.probe(url))?.lastModified }
        Paths.ensure(file.deletingLastPathComponent())
        try Toolchain.swapping { try FileTools.replace(file, with: staging) }
        CacheStamp(size: FileTools.size(of: file), lastModified: stamped, md5: nil)
            .write(besides: file)
    }

    /// RFC 1123, the one shape `Last-Modified` comes in.
    static let httpDate = "EEE, dd MMM yyyy HH:mm:ss zzz"

    /// `Last-Modified`, which HTTP writes one way whatever the machine's locale.
    static func date(of header: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = Self.httpDate
        return formatter.date(from: header)
    }
}
