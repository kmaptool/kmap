import Foundation

extension BuildPipeline {
    enum ElevationBuildStep: Hashable, Sendable {
        case convert, water, trace, summits

        /// Seconds on Germany, per cell and per GB of extract.
        static let secondsPerCell = 0.2
        static let waterSecondsPerGB = 4.0
        static let summitSecondsPerGB = 0.8
    }

    func elevationBuildCourse() -> ProgressCourse<ElevationBuildStep> {
        let (converting, bytes) = state.withLock { ($0.conversion.cells, $0.elevationExtractBytes) }
        let gigabytes = Double(bytes) / 1_073_741_824
        let traced = recipe.contours ? Double(elevationCells().count) : 0
        return ProgressCourse([
            (.convert, Double(converting) * ElevationBuildStep.secondsPerCell),
            (.water, recipe.contours ? gigabytes * ElevationBuildStep.waterSecondsPerGB : 0),
            (.trace, traced * ElevationBuildStep.secondsPerCell),
            (.summits, recipe.demLayer && recipe.fixSummits ? gigabytes * ElevationBuildStep.summitSecondsPerGB : 0)
        ])
    }

    /// Called by a source as it starts converting `cells` tiles.
    func elevationConversionBegins(_ cells: Int) {
        state.withLock { $0.conversion.cells += cells }
    }

    /// Called from any lane as a cell is converted.
    func elevationCellConverted() {
        let (done, cells) = state.withLock { run in
            run.conversion.done += 1
            return (run.conversion.done, run.conversion.cells)
        }
        detail(
            .elevationBuild,
            "converting \(done)/\(cells)",
            fraction: elevationBuildCourse().position(.convert, at: Double(done) / Double(max(1, cells)))
        )
    }
}
