import Foundation

/// The single pass over an extract that precedes mkgmap.
///
/// Four jobs in one read and one write: tag each barrier node with the kind of way it
/// stands on, drop descriptions that only repeat the name, mark areas repeating a venue
/// already on the map, and repair road ends OSM left short of their junction.
struct AnnotatePass {
    var source: URL
    var destination: URL
    /// How far to look for the line a dangling end was meant to join. Zero leaves the
    /// roads exactly as OSM has them.
    var repairRadius: Double = 0
    /// Close a gap something stands in the way of, with a link of its own.
    var bridgeObstacles = false
    /// Which alphabet the repair links are named in.
    var language = "en"
    /// First id for the nodes and links this pass invents. Must be distinct per region in
    /// a multi-region build, or the merged splitter stream collides them.
    var inventedIDBase: Int64 = 1 << 40
    var dropDuplicateDescriptions = false
    var markDuplicateVenues = false
    /// Where the .hgt tiles are, if the contour step has already fetched them.
    var dem: URL?
    /// Contour files to fold into the output, so splitter is handed one input file and
    /// keeps every contour whole where it crosses a tile boundary.
    var contours: [URL] = []

    @discardableResult
    /// Runs the pass with the contours already at hand.
    func run(log: (String) -> Void) throws -> PBFRewriter.Tally {
        try runScansThenWrite(contoursReady: nil, log: log)
    }

    /// Runs the scans first and awaits the contours only between them and the rewrite that
    /// folds them in, so the scans overlap with the contour tracer.
    func run(contoursReady: @escaping () async throws -> [URL],
             log: @escaping (String) -> Void) async throws -> PBFRewriter.Tally {
        let held = self
        return try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let tally = try held.runScansThenWrite(contoursReady: { () throws -> [URL] in
                        // Bridged with a semaphore: the scans run on a plain queue thread,
                        // never the cooperative pool, so blocking here starves nothing.
                        let gate = DispatchSemaphore(value: 0)
                        nonisolated(unsafe) var landed: Result<[URL], Error> = .success([])
                        Task {
                            do { landed = .success(try await contoursReady()) }
                            catch { landed = .failure(error) }
                            gate.signal()
                        }
                        gate.wait()
                        return try landed.get()
                    }, log: log)
                    done.resume(returning: tally)
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    private func runScansThenWrite(contoursReady: (() throws -> [URL])?,
                                   log: (String) -> Void) throws -> PBFRewriter.Tally {
        // Timings per phase, since the extract is read several times over.
        var mark = Date()
        func took(_ what: String) {
            if let line = Measured.line(what, since: mark) { log(line) }
            mark = Date()
        }

        let scanned = runScans()
        took("scanned the extract, three ways at once")
        if Measured.reported {
            for (what, seconds) in scanned.timings.slowestFirst {
                log(String(format: "    %@ %.1f s", what, seconds))
            }
        }
        // Failures are raised in a fixed order, whichever scan finished first.
        if let failure = scanned.repairFailure { throw failure }
        if let failure = scanned.barrierFailure { throw failure }
        if let failure = scanned.venueFailure { throw failure }
        for line in scanned.repairLines { log(line) }

        // The traced contours, awaited only now, with every scan already done. A tracer
        // that failed fails the pass.
        let contourFiles: [URL]
        if let contoursReady { contourFiles = try contoursReady() } else { contourFiles = contours }

        var rewriter = PBFRewriter(url: source, plan: scanned.plan,
                                   network: scanned.network, language: language)
        rewriter.barriers = scanned.barriers
        rewriter.tidyDescriptions = dropDuplicateDescriptions
        rewriter.contours = contourFiles
        rewriter.duplicateVenues = scanned.venues
        let tally = try rewriter.write(to: destination)
        took("wrote the extract")

        report(tally, barriers: scanned.barriers, contourFiles: contourFiles, log: log)
        return tally
    }

    /// What the three scans of the extract brought back. Each scan writes only its own
    /// fields, so the struct is filled from three threads without contention.
    private struct ScanResults {
        var plan = RepairPlan()
        var network = RoadNetwork()
        var repairLines: [String] = []
        var repairFailure: Error?
        var barriers: [Int64: String] = [:]
        var barrierFailure: Error?
        var venues: Set<Int64> = []
        var venueFailure: Error?
        var timings = ScanTimings()
    }

    /// Three independent scans of the same extract, run at once: the road chain makes
    /// the repair plan, the barrier scan tags the gates, the venue scan finds the
    /// repeats. Blocks until all three are done.
    private func runScans() -> ScanResults {
        // One local variable per scan, not fields of one shared struct: each closure may
        // then write its own box without contending for exclusive access to the whole.
        let timings = ScanTimings()

        nonisolated(unsafe) var repair: Result<(RoadNetwork, RepairPlan, [String]), Error>?
        nonisolated(unsafe) var barriers: Result<[Int64: String], Error> = .success([:])
        nonisolated(unsafe) var venues: Result<Set<Int64>, Error> = .success([])

        let scans = DispatchGroup()
        let pool = DispatchQueue.global(qos: .userInitiated)
        if repairRadius > 0 {
            pool.async(group: scans) { [self] in
                timings.timed("repairing road ends") {
                    repair = Result { try repairScan(timings: timings) }
                }
            }
        }
        pool.async(group: scans) {
            timings.timed("classifying barriers") {
                barriers = Result { try BarrierScan.classify(self.source) }
            }
        }
        if markDuplicateVenues {
            pool.async(group: scans) {
                timings.timed("finding repeated venues") {
                    venues = Result { try VenueScan.duplicates(in: self.source) }
                }
            }
        }
        scans.wait()

        var results = ScanResults()
        results.timings = timings
        switch repair {
        case .success(let (network, plan, lines)):
            results.network = network
            results.plan = plan
            results.repairLines = lines
        case .failure(let error):
            results.repairFailure = error
        case nil:
            break
        }
        switch barriers {
        case .success(let tagged): results.barriers = tagged
        case .failure(let error): results.barrierFailure = error
        }
        switch venues {
        case .success(let marked): results.venues = marked
        case .failure(let error): results.venueFailure = error
        }
        return results
    }

    /// The repair scan: load the road network, find the loose ends, plan the repairs.
    ///
    /// - Returns: the loaded network, the plan, and the log lines describing it.
    private func repairScan(timings: ScanTimings) throws
        -> (RoadNetwork, RepairPlan, [String]) {
        var step = Date()
        func part(_ what: String) {
            timings.note("  " + what, seconds: Date().timeIntervalSince(step))
            step = Date()
        }
        let loaded = try RoadNetworkLoader(url: source).load()
        part("read the road network")
        let (found, loose) = RoadRepair(network: loaded, limit: repairRadius)
            .candidates()
        part("found the loose ends")
        let terrain = dem.flatMap {
            FileManager.default.fileExists(atPath: $0.path)
                ? Terrain(directory: $0) : nil
        }
        let made = RepairPlanner(network: loaded, terrain: terrain,
                                 bridging: bridgeObstacles, limit: repairRadius,
                                 inventedIDBase: inventedIDBase)
            .plan(found, loose: loose)
        part("planned the repairs")

        let joined = (made.counts[RepairPlanner.Verdict.joined] ?? 0)
            + made.counts.filter { $0.key.hasPrefix("bridged") }.values
                .reduce(0, +)
        var lines = [
            "joined \(joined) road end(s) no route could get through,"
            + " of \(found.count)" + String(format: " within %.1f m", repairRadius)]
        // Commonest first, and by name where two are equally common: a
        // dictionary has no order of its own, and this list is compared.
        for (reason, count) in made.counts.sorted(by: {
            ($0.value, $1.key) > ($1.value, $0.key)
        }) where reason != RepairPlanner.Verdict.joined {
            let label = reason.hasPrefix("bridged")
                ? reason : "left as mapped, " + reason
            lines.append("  \(label): \(count)")
        }
        return (loaded, made, lines)
    }

    /// The pass's closing summary: what was tagged, folded in, dropped and marked.
    private func report(_ tally: PBFRewriter.Tally, barriers: [Int64: String],
                        contourFiles: [URL], log: (String) -> Void) {
        var kinds: [String: Int] = [:]
        for kind in barriers.values { kinds[kind, default: 0] += 1 }
        log("annotated \(tally.tagged) barrier node(s): "
            + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                .joined(separator: ", "))
        if tally.contourBlocks > 0 {
            log("folded \(contourFiles.count) contour file(s) in, \(tally.contourBlocks) block(s)")
        }
        if tally.dropped > 0 {
            log("dropped \(tally.dropped) description(s) that only repeated the name")
        }
        if tally.marked > 0 {
            log("marked \(tally.marked) area(s) that repeat an enclosing venue")
        }
    }
}

/// Wall-clock per scan, appended from the scan threads under one lock. The scans run at
/// once, so the pass's own phase line reports only the longest; this keeps each one.
final class ScanTimings {
    private var entries: [(String, Double)] = []
    private let lock = NSLock()

    /// Runs `body` and records how long it took under `what`.
    func timed(_ what: String, _ body: () -> Void) {
        let started = Date()
        body()
        note(what, seconds: Date().timeIntervalSince(started))
    }

    func note(_ what: String, seconds: Double) {
        lock.lock(); entries.append((what, seconds)); lock.unlock()
    }

    var slowestFirst: [(String, Double)] {
        lock.lock(); defer { lock.unlock() }
        return entries.sorted { $0.1 > $1.1 }
    }
}
