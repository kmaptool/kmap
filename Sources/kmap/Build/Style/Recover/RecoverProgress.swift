import Foundation

/// What the recovery is doing right now, for a screen to draw.
///
/// The pipeline writes, the render loop reads, and the lock keeps the pair honest —
/// the same shape the build pipeline uses, sized down to four stages.
final class RecoverProgress: @unchecked Sendable {
    enum Stage: Equatable {
        /// Compiling the reader against the installed mkgmap.
        case preparing
        /// Walking the map's tiles. No total exists until it is done, so this stage
        /// shows a count, not a bar.
        case reading
        /// Loading one OSM extract into the ground index.
        case indexing(String)
        /// Matching map elements against that ground — a stage with a true total.
        case matching(String)
        /// Looking up what geometry could not name: unmatched points asked of the
        /// place they stand on, coarse fills of the ways beneath them.
        case placing(String)
        case deriving
    }

    struct Snapshot {
        let stage: Stage
        /// Elements read off the map so far (reading), or matched so far (matching).
        let done: Int
        /// The whole element count while matching; 0 while it is unknown.
        let total: Int

        var fraction: Double? {
            switch stage {
            case .matching, .placing:
                guard total > 0 else { return nil }
                return Double(done) / Double(total)
            default:
                return nil
            }
        }
    }

    private let lock = NSLock()
    private var stage: Stage = .preparing
    private var done = 0
    private var total = 0

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(stage: stage, done: done, total: total)
    }

    func move(to next: Stage) {
        lock.lock(); defer { lock.unlock() }
        stage = next
        done = 0
        total = 0
    }

    /// Another handful done, from whichever core did them.
    func advance(_ many: Int) {
        lock.lock(); defer { lock.unlock() }
        done += many
    }

    func count(_ soFar: Int, of whole: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        done = soFar
        if whole > 0 { total = whole }
    }
}
