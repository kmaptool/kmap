import Foundation

extension ImgContainer {
    struct SubFile {
        let name: String
        let ext: String
        let size: Int
        var blocks: [Int]
        let blockSize: Int

        var fullName: String { "\(name).\(ext)" }
    }
}
