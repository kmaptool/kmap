import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    /// Whether `url` names one of the dated files `latest` stands for, on any host.
    static func isDated(_ url: URL, standingFor latest: URL) -> Bool {
        guard let stem = stem(of: latest) else { return false }
        let name = url.lastPathComponent
        guard name.hasPrefix(stem + "-"), name.hasSuffix(datedSuffix) else { return false }
        let date = name.dropFirst(stem.count + 1).dropLast(datedSuffix.count)
        return date.count == 6 && date.allSatisfy(\.isNumber)
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

    /// The dated names are asked for in 2 waves, the likeliest first: 3 requests
    /// answer most outages, and 7 at once per region is more than a mirror is owed.
    private static let firstWave = 3
    /// The round a throttled mirror is given before it is asked again, as `pause` counts.
    private static let throttledPause = 3

    private static let notFound = 404, tooManyRequests = 429

    private static func status(of error: Error) -> Int? {
        if case DownloadError.badStatus(let code) = error { return code }
        return nil
    }

    /// Probes `latest`, and where it does not answer, the dated files of the last days.
    /// Throws what the alias's last probe threw when nothing answers in any round. A 404
    /// from the alias and from every dated name is final: the region is gone, and asking
    /// again says so more slowly. A 429 stops the asking for that round.
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
                // The alias redirects to a dated file, and proxies keep the redirect and the
                // alias's checksum apart: the file and its checksum are asked by that name.
                let named = isDated(info.finalURL, standingFor: latest) ? info.finalURL : latest
                return ExtractSource(url: named, md5: checksum(of: named), info: info, standIn: nil)
            } catch {
                if Task.isCancelled { throw error }
                var throttled = status(of: error) == tooManyRequests
                var gone = status(of: error) == notFound
                if !throttled {
                    let dated = datedFiles(for: latest, today: today)
                    for wave in [dated.prefix(firstWave), dated.dropFirst(firstWave)] where !wave.isEmpty {
                        let asked = await newestAnswering(Array(wave), probe: probe)
                        if let found = asked.found { return found }
                        gone = gone && asked.allGone
                        if asked.throttled { throttled = true; break }
                    }
                }
                round += 1
                guard round < rounds, !gone else { throw error }
                try await pause(throttled ? throttledPause : round)
            }
        }
    }

    private struct Asked {
        var found: ExtractSource?
        /// Every name answered 404: none of them exists.
        var allGone = true
        /// The mirror said it is being asked too often.
        var throttled = false
    }

    /// Asks for every candidate at once and takes the newest that answers. They are in
    /// date order, newest first.
    ///
    /// Each answer goes to its own place and is read once the group is done, never passed
    /// back through it: on x86-64 Windows, Swift 6.3 corrupts an index a group's task returns.
    private static func newestAnswering(_ candidates: [URL], probe: @escaping Probe) async -> Asked {
        let answers = Locked([Result<Downloader.RemoteInfo, Error>?](repeating: nil, count: candidates.count))
        await withTaskGroup(of: Void.self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    let answer: Result<Downloader.RemoteInfo, Error>
                    do { answer = .success(try await probe(url, datedTimeout)) } catch { answer = .failure(error) }
                    answers.withLock { $0[index] = answer }
                }
            }
        }
        return pickNewest(candidates, answers.withLock { $0 })
    }

    /// The first candidate that answered, and what the rest said.
    private static func pickNewest(
        _ candidates: [URL],
        _ answers: [Result<Downloader.RemoteInfo, Error>?]
    ) -> Asked {
        var asked = Asked()
        for (url, answer) in zip(candidates, answers) {
            switch answer {
            case .success(let info):
                if asked.found == nil {
                    asked.found = ExtractSource(
                        url: url,
                        md5: checksum(of: url),
                        info: info,
                        standIn: url.lastPathComponent
                    )
                }
            case .failure(let error):
                if status(of: error) != notFound { asked.allGone = false }
                if status(of: error) == tooManyRequests { asked.throttled = true }
            case nil:
                asked.allGone = false
            }
        }
        return asked
    }

    private static func checksum(of file: URL) -> URL? {
        URL(string: file.absoluteString + ".md5")
    }
}
