import Foundation

extension BuildPipeline {
    /// Everything about the run that changes while it runs. The stages run on several
    /// tasks at once, the elevation beside the split, and the screen reads from its own
    /// thread, so all of it sits behind one lock.
    struct Run {
        /// The timed pieces of work inside each stage; see `PipelineProgress`.
        var marks: [Mark] = []
        /// The degree cells elevation actually works on, once the region outlines have
        /// had their say. Nil until the elevation stage computes it; see
        /// trimElevationCells().
        var outlineElevationCells: [(lat: Int, lon: Int)]?
        var finished = false
        var failure: String?
        var wasCancelled = false
        var outputs: [Output] = []
        /// The output groups in the order the packer laid them, set by the compile stage;
        /// collect names the files p1, p2... along it.
        var outputGroups: [String] = []
        /// The BaseCamp folder the compile stage wrote, for collect to move.
        var gmapBundle: URL?
        var startedAt = Date()
        var finishedAt: Date?
        /// Private copies of elevation tiles carrying OSM summit heights, written by
        /// `burnPeakElevations` and searched ahead of the shared cache.
        var burnedElevationDirectories: [URL] = []
        /// The ranked .hgt directories, walked once and kept until tiles change.
        var demPaths: [URL]?
        /// Where kmap's own marks ended up when the chosen TYP already drew their
        /// numbers. The rules emitting them are moved to match, in this build's style
        /// snapshot.
        var repairMoves: [MapElementKind: [Int: Int]] = [:]
        /// Data packs found to have moved on; see `StageDataUpdate`.
        var pendingPackUpdates: [(pack: DataPack, news: DataPack.News)] = []

        var runners: [ProcessRunner] = []
        var downloaders: [Downloader] = []
        var task: Task<Void, Never>?
        /// Runs beside the split, unstructured, so `cancel()` has to reach it by hand:
        /// the main task may be waiting on it, and a cancelled task is not released from
        /// a wait.
        var elevation: Task<[URL], Error>?
    }
}
