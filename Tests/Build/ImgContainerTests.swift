import XCTest
@testable import kmap

/// Reading the inside of a Garmin `.img`: a header, a directory of 512-byte entries, and
/// subfiles scattered across the blocks their entry names. kmap reads it to identify and
/// lift out the TYP of a map it did not build.
final class ImgContainerTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: A container built by hand

    private func entry(name: String, ext: String, size: Int, blocks: [Int]) -> [UInt8] {
        ImgFixture.entry(name: name, ext: ext, size: size, blocks: blocks)
    }

    private func container(_ files: [(name: String, ext: String, body: [UInt8])],
                           signature: Bool = true) throws -> URL {
        try ImgFixture.container(files, into: directory, signature: signature)
    }

    private func typBody(family: Int, product: Int, extra: Int = 0) -> [UInt8] {
        ImgFixture.typBody(family: family, product: product, extra: extra)
    }

    // MARK: Recognising one

    func testAContainerIsRecognisedByItsSignatureAndNothingElse() throws {
        let real = try container([("MAKEGMAP", "TYP", typBody(family: 6324, product: 1))])
        XCTAssertTrue(ImgContainer.isImg(real))

        let fake = try container([("MAKEGMAP", "TYP", typBody(family: 1, product: 1))],
                                 signature: false)
        XCTAssertFalse(ImgContainer.isImg(fake))
        XCTAssertTrue(ImgContainer.directory(of: fake).isEmpty)
    }

    func testSomethingThatIsNotAFileAtAllIsRefusedQuietly() {
        let absent = directory.appendingPathComponent("nothing.img")
        XCTAssertFalse(ImgContainer.isImg(absent))
        XCTAssertTrue(ImgContainer.directory(of: absent).isEmpty)
        XCTAssertNil(ImgContainer.typSubFile(in: absent))
        XCTAssertNil(ImgContainer.typIdentity(in: absent))
    }

    func testAFileTooShortToHoldAHeaderIsRefused() throws {
        let stub = directory.appendingPathComponent("short.img")
        try Data([UInt8](repeating: 0, count: 64)).write(to: stub)
        XCTAssertFalse(ImgContainer.isImg(stub))
        XCTAssertTrue(ImgContainer.directory(of: stub).isEmpty)
    }

    // MARK: The directory

    func testEverySubfileIsListedWithItsNameAndSize() throws {
        let url = try container([
            ("63240001", "TRE", [UInt8](repeating: 7, count: 300)),
            ("63240001", "RGN", [UInt8](repeating: 8, count: 900)),
            ("MAKEGMAP", "TYP", typBody(family: 6324, product: 1)),
        ])
        let listed = ImgContainer.directory(of: url)
        XCTAssertEqual(listed.map(\.fullName), ["63240001.TRE", "63240001.RGN", "MAKEGMAP.TYP"])
        XCTAssertEqual(listed[0].size, 300)
        XCTAssertEqual(listed[1].size, 900)
        XCTAssertEqual(listed[0].blockSize, 512)
    }

    func testASubfileIsReadBackThroughItsBlockList() throws {
        // A subfile's blocks need not be contiguous, so reading it walks the block list.
        let body = (0..<1500).map { UInt8($0 % 251) }
        let url = try container([("63240001", "RGN", body),
                                 ("MAKEGMAP", "TYP", typBody(family: 1, product: 1))])
        let sub = try XCTUnwrap(ImgContainer.directory(of: url).first)
        XCTAssertEqual(ImgContainer.read(sub, from: url).map { [UInt8]($0) }, body)
        // A window inside it, crossing a block boundary.
        XCTAssertEqual(ImgContainer.read(sub, from: url, offset: 500, length: 200)
                        .map { [UInt8]($0) }, Array(body[500..<700]))
        // Past the end reads nothing rather than reading the next subfile.
        XCTAssertNil(ImgContainer.read(sub, from: url, offset: 1500, length: 10))
    }

    // MARK: The TYP inside

    func testTheEmbeddedStyleIsFoundAndIdentifiedWithoutExtractingIt() throws {
        let url = try container([
            ("63240001", "TRE", [UInt8](repeating: 0, count: 100)),
            ("MAPSTYLE", "TYP", typBody(family: 6324, product: 2, extra: 4000)),
        ])
        XCTAssertEqual(ImgContainer.typSubFile(in: url)?.fullName, "MAPSTYLE.TYP")
        let identity = try XCTUnwrap(ImgContainer.typIdentity(in: url))
        XCTAssertEqual(identity.familyID, 6324)
        XCTAssertEqual(identity.productID, 2)
        XCTAssertEqual(identity.size, 0x40 + 4000)
    }

    func testAMapWithNoStyleInsideSaysSoRatherThanGuessing() throws {
        let url = try container([("63240001", "TRE", [UInt8](repeating: 0, count: 100))])
        XCTAssertNil(ImgContainer.typSubFile(in: url))
        XCTAssertNil(ImgContainer.typIdentity(in: url))
        XCTAssertFalse(ImgContainer.extractTYP(from: url,
                                               to: directory.appendingPathComponent("a.typ")))
    }

    func testSomethingCalledTYPThatIsNotOneIsNotIdentified() throws {
        // The extension is only a claim; the "GARMIN TYP" mark inside is the statement.
        let url = try container([("MAKEGMAP", "TYP", [UInt8](repeating: 0x41, count: 0x40))])
        XCTAssertNotNil(ImgContainer.typSubFile(in: url))
        XCTAssertNil(ImgContainer.typIdentity(in: url))
    }

    func testAStyleWithNoFamilyIsNotIdentifiedEither() throws {
        // Family zero would collide with everything on the device.
        let url = try container([("MAKEGMAP", "TYP", typBody(family: 0, product: 1))])
        XCTAssertNil(ImgContainer.typIdentity(in: url))
    }

    func testExtractingWritesTheStyleOutWholeAndCreatesTheFolderForIt() throws {
        let body = typBody(family: 6324, product: 1, extra: 2000)
        let url = try container([("MAPSTYLE", "TYP", body)])
        let out = directory.appendingPathComponent("styles/borrowed/style.typ")
        XCTAssertTrue(ImgContainer.extractTYP(from: url, to: out))
        XCTAssertEqual([UInt8](try Data(contentsOf: out)), body)
    }
}
