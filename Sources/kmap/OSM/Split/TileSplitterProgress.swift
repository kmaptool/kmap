import Foundation

extension TileSplitter {
    func reader(_ index: Int, reporting report: ProgressReport) -> PBFReader {
        var reader = reader(options.inputs[index])
        reader.progress = report.part(index, of: inputCourse)
        return reader
    }
}
