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
    ///
    /// - Parameter lockHeld: the caller holds `holdingDownload(of:)` already, for longer
    ///   than the download: a second hold in 1 process would wait on itself.
    func download(url: URL, to destination: URL, connections: Int, lockHeld: Bool = false) async throws -> Int64 {
        let lock = lockHeld ? nil : try await holdingDownload(of: destination)
        defer { withExtendedLifetime(lock) {} }
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

    /// The lock on `destination`'s download, waited for while another kmap holds it: both
    /// would write into the same part files.
    func holdingDownload(of destination: URL) async throws -> HeldLock {
        Paths.ensure(Paths.locks)
        let file = Paths.locks.appendingPathComponent(
            "download-\(FileTools.slugify(destination.lastPathComponent)).lock"
        )
        var told = false
        while true {
            if let lock = HeldLock(trying: file) { return lock }
            if !told {
                log.step("another kmap is downloading \(destination.lastPathComponent) — waiting for it")
                told = true
            }
            if wasCancelled { throw DownloadError.cancelled }
            try await Task.sleep(nanoseconds: 500_000_000)
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
            plan.append(RangeSession.Part(index: i, start: start, end: end, url: files.part(i), total: info.size))
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

    /// Downloads bytes `start..<start + count` of `url`, resuming a part file. The server
    /// must serve ranges.
    func download(url: URL, from start: Int64, count: Int64, to destination: URL) async throws {
        Paths.ensure(destination.deletingLastPathComponent())
        let part = RangeSession.Part(
            index: 0,
            start: start,
            end: start + count - 1,
            url: PartFiles(destination: destination).part(0)
        )
        if part.written > part.length { FileTools.removeIfPresent(part.url) }
        progress.begin(total: count, partTotals: [count], alreadyOnDisk: part.written)
        progress.seedPart(0, bytes: part.written)
        progress.setStage("downloading")
        // A clean answer can still end short; each retry picks up where it stopped.
        for _ in 0..<3 where part.written < part.length {
            try await fetch(part: part, from: url, ranged: true)
            try Task.checkCancellation()
        }
        guard part.written == count else {
            FileTools.removeIfPresent(part.url)
            throw DownloadError.io("\(url.lastPathComponent): \(part.written) of \(count) bytes arrived")
        }
        FileTools.removeIfPresent(destination)
        try FileTools.move(part.url, to: destination)
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
                // Every byte is on disk: a drop after the last one is not a failure.
                if written >= part.length { return }
                // Bytes arrived before the drop, so the count starts again.
                if written > before { failures = 0 }
                // Without ranges there is no picking up, only starting over.
                // A redirect loop too: a mirror's proxies can disagree, one looping while
                // the next serves the file.
                let passing = Self.worthRetrying(error) || (error as? URLError)?.code == .httpTooManyRedirects
                guard ranged, written < part.length, failures < Self.retriesPerPart, passing
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
        if case DownloadError.badStatus(let code) = error { return code == 429 || (500...599).contains(code) }
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
