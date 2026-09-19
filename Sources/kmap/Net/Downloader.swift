import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads one file over several connections, resuming whatever a previous run left in
/// `.partN` files. The ranges go through a `RangeSession`; the files are `PartFiles`.
final class Downloader: Sendable {
    let progress = DownloadProgress()
    private let log: Log
    private let session: RangeSession

    /// Consecutive retries allowed per part. Any byte that arrives resets the count, so
    /// this bounds a dead connection rather than a slow one.
    private static let retriesPerPart = 8

    /// A retry waits twice as long as the last one, in seconds, up to this.
    static let backoffCap = 8

    init(log: Log) {
        self.log = log
        session = RangeSession(progress: progress)
    }

    func cancel() { session.cancel() }

    /// Whether `cancel()` has been called.
    var wasCancelled: Bool { session.isCancelled }

    // MARK: Download

    /// Downloads `url` to `destination`, resuming any `.partN` files left by a previous
    /// run.
    ///
    /// - Returns: The bytes fetched over the network this time.
    @discardableResult
    func download(url: URL, to destination: URL, connections: Int) async throws -> Int64 {
        do {
            return try await download(
                url: url,
                to: destination,
                connections: connections,
                ranged: nil
            )
        } catch DownloadError.rangesIgnored {
            // HEAD promised ranges and GET ignored them, so the parts were laid out for
            // ranges that will not be served: start over on one connection.
            log.warn("server ignored the range request — starting over on one connection")
            let files = PartFiles(destination: destination)
            files.removeParts()
            FileTools.removeIfPresent(files.layout)
            return try await download(
                url: url,
                to: destination,
                connections: 1,
                ranged: false
            )
        }
    }

    /// - Parameter ranged: Overrides the probe's range support; nil trusts the probe.
    private func download(
        url: URL,
        to destination: URL,
        connections: Int,
        ranged: Bool?
    ) async throws -> Int64 {
        progress.setStage("probing")
        var info = try await Downloader.probeRetrying(url)
        if let ranged { info.acceptsRanges = ranged }

        let partCount = info.acceptsRanges ? max(1, min(connections, PartFiles.maxParts)) : 1
        if !info.acceptsRanges && connections > 1 {
            log.warn("server will not serve byte ranges — falling back to a single connection")
        }

        Paths.ensure(destination.deletingLastPathComponent())
        let files = PartFiles(destination: destination)
        // Without ranges nothing can be picked up: the server sends the file from the top.
        if !info.acceptsRanges { files.removeParts() }

        // Contiguous ranges, the last one taking the remainder.
        let chunk = info.size / Int64(partCount)
        var plan: [RangeSession.Part] = []
        for i in 0..<partCount {
            let start = Int64(i) * chunk
            let end = (i == partCount - 1) ? info.size - 1 : start + chunk - 1
            plan.append(RangeSession.Part(index: i, start: start, end: end, url: files.part(i)))
        }
        files.keepLayout(size: info.size, count: partCount)

        // Whatever each part already holds is a downloaded prefix of its range; one longer
        // than its range cannot be, and goes.
        for part in plan where part.written > part.length {
            FileTools.removeIfPresent(part.url)
        }
        let onDisk = plan.map(\.written)
        let alreadyOnDisk = onDisk.reduce(0, +)

        progress.begin(total: info.size, partTotals: plan.map(\.length), alreadyOnDisk: alreadyOnDisk)
        for part in plan { progress.seedPart(part.index, bytes: onDisk[part.index]) }

        if alreadyOnDisk > 0 {
            log.append("resuming — \(Fmt.bytes(alreadyOnDisk)) of \(Fmt.bytes(info.size)) already on disk")
        }
        progress.setStage("downloading")

        // Every part runs concurrently; the first failure cancels the rest.
        let source = info.finalURL
        let acceptsRanges = info.acceptsRanges
        try await withThrowingTaskGroup(of: Void.self) { group in
            for part in plan where onDisk[part.index] < part.length {
                // The group ends inside this call, so `self` outlives every child task.
                group.addTask {
                    try await self.fetch(part: part, from: source, ranged: acceptsRanges)
                }
            }
            for try await _ in group {}
        }

        try Task.checkCancellation()

        progress.setStage("assembling")
        try files.assemble(plan.map(\.url), expectedSize: info.size)
        FileTools.removeIfPresent(files.layout)
        return info.size - alreadyOnDisk
    }

    /// Fetches one part, resuming where it stopped for as long as it makes progress.
    private func fetch(part: RangeSession.Part, from url: URL, ranged: Bool) async throws {
        var failures = 0
        while true {
            let before = part.written
            do {
                try await session.fetch(part, from: url, ranged: ranged)
                return
            } catch {
                if Task.isCancelled { throw error }
                let written = part.written
                // Bytes arrived before the drop, so the count starts again.
                if written > before { failures = 0 }
                // Without ranges there is no picking up, only starting over.
                guard ranged, written < part.length,
                    failures < Self.retriesPerPart, Self.worthRetrying(error)
                else { throw error }
                failures += 1
                if failures == 1 {
                    log.warn(
                        "connection dropped with \(Fmt.bytes(part.length - written))"
                            + " left of part \(part.index + 1) — picking it up again"
                    )
                }
                try await Self.backOff(after: failures)
            }
        }
    }

    // MARK: Retrying

    /// Whether `error` is transient: a 5xx status, or a connection-level `URLError`. A
    /// 4xx, a checksum failure, a full disk and a cancellation are all final.
    static func worthRetrying(_ error: Error) -> Bool {
        if case DownloadError.badStatus(let code) = error { return (500...599).contains(code) }
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
            .badServerResponse, .zeroByteResource:
            return true
        default:
            return false
        }
    }

    /// Sleeps before the retry after `failures` consecutive failures: 2, 4, 8 seconds.
    static func backOff(after failures: Int) async throws {
        let seconds = min(backoffCap, 1 << failures)
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
}
