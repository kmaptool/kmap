import Foundation

/// How often a build asks the mirrors whether the data packs have moved on. The
/// boundaries are 2.5 GB, so this is a question about bandwidth as much as freshness.
enum ToolchainUpdates: String, Codable, CaseIterable {
    case everyBuild, weekly, monthly, halfYear, year, never

    var title: String {
        switch self {
        case .everyBuild: return t("every build")
        case .weekly: return t("once a week")
        case .monthly: return t("once a month")
        case .halfYear: return t("every six months")
        case .year: return t("once a year")
        case .never: return t("never")
        }
    }

    /// How long an answer stays good. Nil where no question is asked.
    var interval: TimeInterval? {
        let day = TimeInterval.day
        switch self {
        case .everyBuild: return 0
        case .weekly: return 7 * day
        case .monthly: return 30 * day
        case .halfYear: return 182 * day
        case .year: return 365 * day
        case .never: return nil
        }
    }

    /// Whether a check made then still counts now.
    func stillGood(checked: Date?, now: Date = Date()) -> Bool {
        guard let interval else { return true }
        guard let checked else { return false }
        return now.timeIntervalSince(checked) < interval
    }
}

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
        what: "coastline data")

    static let bounds = DataPack(
        id: "bounds",
        url: URL(string: "https://www.thkukuk.de/osm/data/bounds-latest.zip")!,
        file: Paths.boundsData,
        what: "boundary data")

    static let all: [DataPack] = [sea, bounds]

    static func named(_ id: String) -> DataPack? { all.first { $0.id == id } }

    /// Below this it is the remains of a download: the smallest pack is 344 MB.
    static let smallestPack: Int64 = 1_000_000

    /// Where an update is written while it comes down, beside the pack it replaces.
    static let stagingSuffix = "new"

    var isInstalled: Bool {
        FileTools.exists(file) && FileTools.size(of: file) > Self.smallestPack
    }
}

extension DataPack {
    /// What the server holds, when it is not what is on disk.
    struct News: Equatable {
        let size: Int64
        let lastModified: String?
        let published: Date?

        /// For the log and the stage line: the date if the server gave one, the size if
        /// it did not.
        var describedShortly: String {
            published.map { "\(Fmt.day($0)) · \(Fmt.bytes(size))" } ?? Fmt.bytes(size)
        }
    }

    /// The pack the server publishes, when it is newer than the one here. Nil for
    /// everything else: an uninstalled pack, an unreachable server, or a server that says
    /// neither a date nor a different size — none of which is worth 2 GB of traffic.
    func newer(probe: (URL) async throws -> Downloader.RemoteInfo = {
        try await Downloader.probeRetrying($0)
    }) async -> News? {
        guard isInstalled, let remote = try? await probe(url) else { return nil }
        let published = remote.lastModified.flatMap(Self.date(of:))
        let stamp = CacheStamp.read(besides: file)

        if let stamp {
            // Stamped when it was fetched: the exact question, answered exactly.
            if stamp.matches(size: remote.size, lastModified: remote.lastModified) { return nil }
        } else if let published, let here = FileTools.modified(of: file) {
            // Installed before kmap stamped these, so the file's own date stands in: it is
            // when the download finished, never earlier than what was published by then.
            if published <= here { return nil }
        } else if remote.size == FileTools.size(of: file) {
            // Nothing to compare but the size, and it agrees.
            return nil
        }
        return News(size: remote.size, lastModified: remote.lastModified, published: published)
    }

    /// Fetches the pack and puts it in place, stamped with what the server said. Written
    /// beside the one it replaces and moved over it only when whole, so an update stopped
    /// halfway leaves the old pack rather than none.
    func fetch(using downloader: Downloader, connections: Int = 4,
               lastModified: String? = nil) async throws {
        let staging = file.appendingPathExtension(Self.stagingSuffix)
        try await downloader.download(url: url, to: staging, connections: connections)
        var stamped = lastModified
        if stamped == nil { stamped = (try? await Downloader.probe(url))?.lastModified }
        Paths.ensure(file.deletingLastPathComponent())
        FileTools.removeIfPresent(file)
        try FileManager.default.moveItem(at: staging, to: file)
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
