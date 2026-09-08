import Foundation

/// A Garmin `.img` assembled byte by byte: the header, a directory of 512-byte entries and
/// every subfile scattered across the blocks its entry names.
enum ImgFixture {
    static let blockSize = 512

    /// One directory entry: the marker, the name, the size and the blocks it lives in.
    static func entry(name: String, ext: String, size: Int, blocks: [Int]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 512)
        out[0] = 1
        for (i, byte) in Array(name.padding(toLength: 8, withPad: " ", startingAt: 0).utf8)
            .enumerated() { out[1 + i] = byte }
        for (i, byte) in Array(ext.padding(toLength: 3, withPad: " ", startingAt: 0).utf8)
            .enumerated() { out[9 + i] = byte }
        out[0x0C] = UInt8(size & 0xFF)
        out[0x0D] = UInt8((size >> 8) & 0xFF)
        out[0x0E] = UInt8((size >> 16) & 0xFF)
        out[0x0F] = UInt8((size >> 24) & 0xFF)
        // Unused block slots are 0xFFFF, not zero -- zero is a real block number.
        for slot in 0..<((512 - 0x20) / 2) {
            out[0x20 + slot * 2] = 0xFF
            out[0x20 + slot * 2 + 1] = 0xFF
        }
        for (slot, block) in blocks.enumerated() {
            out[0x20 + slot * 2] = UInt8(block & 0xFF)
            out[0x20 + slot * 2 + 1] = UInt8((block >> 8) & 0xFF)
        }
        return out
    }

    /// Writes a container holding the given subfiles, each starting at its own block.
    /// Returns its URL. `signature` off writes something that is not a `.img` at all.
    static func container(_ files: [(name: String, ext: String, body: [UInt8])],
                              into directory: URL, signature: Bool = true) throws -> URL {
        // Blocks 0-1: header. 2-4: the directory. 5 onwards: the subfiles.
        var image = [UInt8](repeating: 0, count: ImgFixture.blockSize * 2)
        if signature {
            for (i, byte) in Array("DSKIMG".utf8).enumerated() { image[0x10 + i] = byte }
        }
        image[0x61] = 9                       // block size 1 << (9 + 0)
        image[0x62] = 0
        image[0x40] = 2                       // the directory starts at sector 2

        // The directory needs a block per entry, one for itself and one per subfile; its
        // own block list bounds the walk.
        let directoryBlocks = Array(2..<(3 + files.count))
        var entries: [[UInt8]] = [ImgFixture.entry(name: "        ", ext: "   ", size: 0,
                                        blocks: directoryBlocks)]
        var bodies: [UInt8] = []
        let firstBodyBlock = directoryBlocks.last! + 1
        var nextBlock = firstBodyBlock
        for file in files {
            let needed = max(1, (file.body.count + ImgFixture.blockSize - 1) / ImgFixture.blockSize)
            entries.append(ImgFixture.entry(name: file.name, ext: file.ext, size: file.body.count,
                                 blocks: Array(nextBlock..<(nextBlock + needed))))
            var padded = file.body
            padded.append(contentsOf: [UInt8](repeating: 0,
                                              count: needed * ImgFixture.blockSize - padded.count))
            bodies.append(contentsOf: padded)
            nextBlock += needed
        }
        for slot in entries { image.append(contentsOf: slot) }
        // The directory occupies whole blocks whatever it holds.
        while image.count < firstBodyBlock * ImgFixture.blockSize { image.append(0) }
        image.append(contentsOf: bodies)

        let url = directory.appendingPathComponent("map.img")
        try Data(image).write(to: url)
        return url
    }

    /// A TYP header as the format has it: the length, "GARMIN TYP", then the family and
    /// product at 0x2F and 0x31.
    static func typBody(family: Int, product: Int, extra: Int = 0) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 0x40 + extra)
        for (i, byte) in Array("GARMIN TYP".utf8).enumerated() { out[2 + i] = byte }
        out[0x2F] = UInt8(family & 0xFF)
        out[0x30] = UInt8((family >> 8) & 0xFF)
        out[0x31] = UInt8(product & 0xFF)
        out[0x32] = UInt8((product >> 8) & 0xFF)
        return out
    }
}
