import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a region's extract is to be had right now.
struct ExtractSource {
    /// The file to fetch: the mirror's `-latest` name, or a dated file standing in.
    let url: URL
    /// Its published checksum.
    let md5: URL?
    let info: Downloader.RemoteInfo
    /// The dated file's name, where `-latest` was not being served.
    let standIn: String?
}

/// Finds a region's extract. The mirror publishes each one twice: under a dated name,
/// and under `-latest`, an alias to the newest of those. When the server behind the
/// mirror's proxies fails, the alias goes first: it redirects to itself, answers 502 or
/// simply hangs, as does the page listing the files, while the proxies go on serving the
/// dated files they hold. So where the alias does not answer, the last few days' files
/// are asked for by name, all at once, and the newest that answers is the extract.
enum ExtractLocator {
    private static let latestSuffix = "-latest.osm.pbf"
    private static let datedSuffix = ".osm.pbf"

    /// How many days back a dated file is looked for.
    private static let daysBack = 6
    /// A HEAD answers in a fraction of a second from a healthy mirror; these are how long
    /// a hanging one is given, for the alias and for each dated name.
    private static let aliasTimeout: TimeInterval = 8, datedTimeout: TimeInterval = 6
    /// Rounds of asking, with a pause between: one dropped answer must not read as a
    /// mirror that is down.
    private static let rounds = 3

    typealias Probe = @Sendable (URL, TimeInterval) async throws -> Downloader.RemoteInfo

    private static func stem(of latest: URL) -> String? {
        let name = latest.lastPathComponent
        return name.hasSuffix(latestSuffix) ? String(name.dropLast(latestSuffix.count)) : nil
    }

    /// The names the last few days' files have, newest first. The mirror dates its files
    /// in UTC, year first.
    static func datedFiles(for latest: URL, today: Date = Date()) -> [URL] {
        guard let stem = stem(of: latest) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return (0...daysBack).compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }
            let date = String(format: "%02d%02d%02d", year % 100, month, dayOfMonth)
            return latest.deletingLastPathComponent().appendingPathComponent("\(stem)-\(date)\(datedSuffix)")
        }
    }

    /// Probes `latest`, and where it does not answer, the dated files of the last days.
    /// Throws what the alias's last probe threw when nothing answers in any round.
    static func locate(
        _ latest: URL,
        today: Date = Date(),
        probe: @escaping Probe = { try await Downloader.probe($0, timeout: $1) },
        pause: (Int) async throws -> Void = Downloader.backOff
    ) async throws -> ExtractSource {
        var round = 0
        while true {
            do {
                let info = try await probe(latest, aliasTimeout)
                return ExtractSource(url: latest, md5: checksum(of: latest), info: info, standIn: nil)
            } catch {
                if Task.isCancelled { throw error }
                if let found = await newestAnswering(datedFiles(for: latest, today: today), probe: probe) {
                    return found
                }
                round += 1
                guard round < rounds else { throw error }
                try await pause(round)
            }
        }
    }

    /// Asks for every candidate at once and takes the newest that answers. They are in
    /// date order, newest first.
    private static func newestAnswering(_ candidates: [URL], probe: @escaping Probe) async -> ExtractSource? {
        await withTaskGroup(of: (Int, Downloader.RemoteInfo?).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask { (index, try? await probe(url, datedTimeout)) }
            }
            var best: (index: Int, info: Downloader.RemoteInfo)?
            for await (index, info) in group {
                guard let info else { continue }
                if best.map({ index < $0.index }) ?? true { best = (index, info) }
            }
            guard let best else { return nil }
            let url = candidates[best.index]
            return ExtractSource(url: url, md5: checksum(of: url), info: best.info, standIn: url.lastPathComponent)
        }
    }

    private static func checksum(of file: URL) -> URL? {
        URL(string: file.absoluteString + ".md5")
    }
}
