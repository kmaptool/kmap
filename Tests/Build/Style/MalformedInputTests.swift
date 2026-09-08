import XCTest
@testable import kmap

/// Readers fed foreign files, broken on purpose.
///
/// A malformed file traps rather than throwing, so every read is bounds-checked and every
/// size taken off the wire is a claim, not a fact. The assertion is that the reader returns.
final class MalformedInputTests: XCTestCase {

    /// Deterministic noise, so that a failure reproduces.
    private struct Noise: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// A TYP header good enough to pass the signature check, so mutations land in the parser.
    private func plausibleTyp() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        bytes[0] = 0x5B
        for (i, b) in Array("GARMIN TYP".utf8).enumerated() { bytes[2 + i] = b }
        bytes[0x2F] = 0x2A
        bytes[0x31] = 0x01
        return bytes
    }

    // MARK: A compiled TYP

    func testABrokenTypIsReadOrRefusedButNeverFatal() {
        var noise = Noise(state: 0x5EED)
        let base = plausibleTyp()

        for round in 0..<400 {
            var bytes = base
            // One to forty bytes rewritten: enough to make lengths, offsets and counts lie
            // without reducing the file to noise.
            for _ in 0...(round % 40) {
                let at = Int.random(in: 0..<bytes.count, using: &noise)
                bytes[at] = UInt8.random(in: 0...255, using: &noise)
            }
            _ = try? TypBinary.decode(bytes)
        }
    }

    func testPureNoiseIsRefusedAtEveryLength() {
        var noise = Noise(state: 0xC0FFEE)
        for length in [0, 1, 2, 12, 0x40, 0x5B, 0x5C, 0x100, 4096] {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &noise) }
            _ = try? TypBinary.decode(bytes)
        }
    }

    func testATruncatedTypStopsWhereItRunsOut() {
        // A download that stopped partway.
        let whole = plausibleTyp()
        for length in stride(from: 0, through: whole.count, by: 7) {
            _ = try? TypBinary.decode(Array(whole.prefix(length)))
        }
    }

    // MARK: A Garmin container

    func testABrokenContainerIsReadOrRefusedButNeverFatal() throws {
        var noise = Noise(state: 0xBADF00D)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        for round in 0..<60 {
            // A container is read by seeking around a block list taken from the file, so the
            // file has to be long enough for the header to be reached.
            var bytes = [UInt8](repeating: 0, count: 0x2000)
            for (i, b) in Array("DSKIMG".utf8).enumerated() { bytes[0x10 + i] = b }
            for _ in 0..<(round + 1) * 8 {
                let at = Int.random(in: 0..<bytes.count, using: &noise)
                bytes[at] = UInt8.random(in: 0...255, using: &noise)
            }
            let url = folder.appendingPathComponent("round-\(round).img")
            try Data(bytes).write(to: url)

            let files = ImgContainer.directory(of: url)
            // Whatever it found, reading it must stay inside the file it came from.
            for file in files.prefix(4) {
                let data = ImgContainer.read(file, from: url)
                XCTAssertLessThanOrEqual(data?.count ?? 0, bytes.count,
                                         "a subfile cannot be bigger than the file holding it")
            }
            _ = ImgContainer.typIdentity(in: url)
        }
    }

    func testASubFileClaimingFourGigabytesDoesNotAskForFourGigabytes() throws {
        // The size is a 32-bit field off a foreign file; believed, it is a gigabyte-scale
        // allocation.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("huge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("small.img")
        try Data([UInt8](repeating: 0, count: 0x1000)).write(to: url)

        let liar = ImgContainer.SubFile(name: "LIAR", ext: "TYP", size: Int(UInt32.max),
                                        blocks: [1, 2], blockSize: 512)
        let data = ImgContainer.read(liar, from: url)
        XCTAssertLessThanOrEqual(data?.count ?? 0, 0x1000)
    }

    // MARK: TYP source, and icons off a disk

    func testBrokenSourceParsesToSomethingRatherThanFalling() {
        let bad = [
            "",
            "[_point]",
            "[_point]\nType=0x2a00\n",                       // no [end]
            "[_point]\nType=not a number\n[end]",
            "[_point]\nXpm=\"999999 999999 99 9\"\n[end]",   // sizes that are not sizes
            "[_point]\nXpm=\"4 4 2 1\"\n\"! c #FF0000\"\n\"##\"\n[end]",   // short rows
            "[_polygon]\nXpm=\"0 0 -1 -1\"\n[end]",
            "[_line]\nXpm=\"2 2 1 1\"\n\"! c none\"\n\"!!!!!!!!!!!!\"\n[end]",  // long rows
            String(repeating: "[_point]\n", count: 500),
        ]
        for text in bad {
            let source = TypSource.parse(text)
            // The text handed back is the text given.
            XCTAssertEqual(source.text, text)
            for section in MapElementKind.allCases.flatMap({ source.sections($0) }) {
                _ = section.picture?.pixels()
                _ = section.colourSlots
                _ = section.patternIsBlank
            }
        }
    }

    func testAnIconThatIsNotAnIconIsRefused() throws {
        var noise = Noise(state: 0x1C04)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        // Files named like pictures, made of noise: a refusal must come back as an error.
        for suffix in ["png", "jpg", "svg", "gif", "tif"] {
            let url = folder.appendingPathComponent("noise.\(suffix)")
            let bytes = (0..<2048).map { _ in UInt8.random(in: 0...255, using: &noise) }
            try Data(bytes).write(to: url)
            _ = try? IconImport.load(url, size: 20)
        }
    }
}
