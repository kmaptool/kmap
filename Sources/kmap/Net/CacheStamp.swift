import Foundation

/// What the server said about an extract when it was cached, kept beside the file.
///
/// Every build asks two questions about a cached extract, and they cost very different
/// amounts. "Has the source changed?" is one HEAD request. "Is what is on disk still
/// whole?" means reading the file end to end — a second or so for a continent on this
/// machine, considerably more on a laptop with a spinning disk, and it happened on every
/// build. Asking the cheap question first means an extract that has not moved is never
/// hashed at all.
///
/// It also fills a hole: an extract published without a `.md5` had no freshness test of
/// any kind, so the whole country was downloaded again every single build.
struct CacheStamp: Codable, Equatable {
    /// What the server reported the last time this file was fetched.
    var size: Int64
    /// The server's `Last-Modified`, verbatim. Compared as a string rather than parsed:
    /// the only question is whether the server is still saying the same thing.
    var lastModified: String?
    /// The checksum, when one was published. Kept so a stamp is enough to re-verify.
    var md5: String?

    static func url(for file: URL) -> URL {
        file.appendingPathExtension("stamp")
    }

    static func read(besides file: URL) -> CacheStamp? {
        guard let data = try? Data(contentsOf: url(for: file)) else { return nil }
        return try? JSONDecoder().decode(CacheStamp.self, from: data)
    }

    func write(besides file: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url(for: file), options: .atomic)
    }

    static func remove(besides file: URL) {
        FileTools.removeIfPresent(url(for: file))
    }

    /// Whether the server is still offering exactly what was cached.
    ///
    /// Both halves have to agree, and a server that reports neither is not taken as
    /// agreement: with no size and no date there is nothing here that could tell a new
    /// extract from the old one.
    func matches(size remoteSize: Int64, lastModified remoteModified: String?) -> Bool {
        guard remoteSize > 0, remoteSize == size else { return false }
        guard let remoteModified, let lastModified else { return false }
        return remoteModified == lastModified
    }
}
