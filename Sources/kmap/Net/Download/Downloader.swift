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

    /// Tries of a part answered without its range before the server is taken to ignore them.
    static let rangeRetries = 2

    /// Clean answers in a row that bring no byte before a part is given up as short.
    static let fruitlessAnswers = 3

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
    /// - Parameter lockHeld: the caller holds `holdingDownload(of:)` already, for longer
    ///   than the download: a second hold in 1 process would wait on itself.
    /// - Returns: The bytes fetched over the network this time.
    @discardableResult
    func download(url: URL, to destination: URL, connections: Int, lockHeld: Bool = false) async throws -> Int64 {
        let lock = lockHeld ? nil : try await holdingDownload(of: destination)
        defer { withExtendedLifetime(lock) {} }
        do {
            return try await restartingIfChanged(url: url, to: destination, connections: connections)
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

    /// The download, started over once where the server's copy was replaced while it ran.
    private func restartingIfChanged(url: URL, to destination: URL, connections: Int) async throws -> Int64 {
        do {
            return try await download(url: url, to: destination, connections: connections, ranged: nil)
        } catch DownloadError.changedMeanwhile {
            // Its parts are of the copy before; the next probe sizes the new one.
            log.warn("\(destination.lastPathComponent) changed on the server meanwhile — starting over")
            let files = PartFiles(destination: destination)
            files.removeParts()
            FileTools.removeIfPresent(files.layout)
            return try await download(url: url, to: destination, connections: connections, ranged: nil)
        }
    }

    /// The file the lock on `destination`'s download is held on. Named with its folder
    /// too: 2 sources keep tiles of 1 name, each in its own.
    static func lockFile(for destination: URL) -> URL {
        let folder = destination.deletingLastPathComponent().lastPathComponent
        return Paths.locks.appendingPathComponent(
            "download-\(FileTools.slugify(folder))-\(FileTools.slugify(destination.lastPathComponent)).lock"
        )
    }

    /// The lock on `destination`'s download, waited for while another kmap holds it: both
    /// would write into the same part files.
    func holdingDownload(of destination: URL) async throws -> HeldLock {
        Paths.ensure(Paths.locks)
        let file = Self.lockFile(for: destination)
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

        // A part of no bytes is never fetched, and its file never made.
        let partCount =
            info.acceptsRanges ? max(1, min(connections, PartFiles.maxParts, Int(min(info.size, Int64(Int.max))))) : 1
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
            plan.append(
                RangeSession.Part(
                    index: i,
                    start: start,
                    end: end,
                    url: files.part(i),
                    total: info.size,
                    lastModified: info.lastModified
                )
            )
        }
        files.keepLayout(size: info.size, count: partCount, lastModified: info.lastModified)

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
    ///
    /// - Parameter locking: false where no other kmap writes `destination`, or the caller
    ///   holds a lock over it.
    func download(url: URL, from start: Int64, count: Int64, to destination: URL, locking: Bool = true) async throws {
        // A range a damaged index names: its end would overflow.
        guard start >= 0, count > 0, start <= Int64.max - count else {
            throw DownloadError.io("\(url.lastPathComponent): no such range as \(count) bytes from \(start)")
        }
        Paths.ensure(destination.deletingLastPathComponent())
        // 2 kmaps would append to 1 part: one waits, and finds it done.
        let lock = locking ? try await holdingDownload(of: destination) : nil
        defer { withExtendedLifetime(lock) {} }
        if FileTools.size(of: destination) == count { return }
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
        // Picked up again inside for as long as answers bring bytes.
        try await fetch(part: part, from: url, ranged: true)
        try Task.checkCancellation()
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
        // A mirror's proxies can differ, 1 ignoring ranges: asked again before every part
        // is thrown away for it.
        var ignored = 0
        var fruitless = 0
        while true {
            let before = part.written
            do {
                try await session.fetch(part, from: url, ranged: ranged)
                // A clean answer can end short, a proxy capping what it relays: asked again
                // from there while answers bring bytes. The assembly reports one still short.
                guard ranged, part.written < part.length else { return }
                // Bytes arrived, so both counts start again.
                if part.written > before {
                    fruitless = 0
                    failures = 0
                } else {
                    fruitless += 1
                    if fruitless >= Self.fruitlessAnswers { return }
                    try await Self.backOff(after: fruitless)
                }
                continue
            } catch {
                if Task.isCancelled { throw error }
                if case DownloadError.rangesIgnored = error, ranged, ignored < Self.rangeRetries {
                    ignored += 1
                    try await Self.backOff(after: ignored)
                    continue
                }
                let written = part.written
                // Every byte is on disk: a drop after the last one is not a failure.
                if written >= part.length { return }
                // Bytes arrived before the drop, so the count starts again; not without
                // ranges, where the next try starts over from the top.
                if ranged, written > before { failures = 0 }
                // A redirect loop too: a mirror's proxies can disagree, one looping while
                // the next serves the file.
                let passing = Self.worthRetrying(error) || (error as? URLError)?.code == .httpTooManyRedirects
                guard failures < Self.retriesPerPart, passing else { throw error }
                failures += 1
                // Without ranges the part starts over, and so does its count.
                if !ranged { progress.restartPart(part.index) }
                if failures == 1, !ranged {
                    log.warn("connection dropped — starting the download over")
                } else if failures == 1 {
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
