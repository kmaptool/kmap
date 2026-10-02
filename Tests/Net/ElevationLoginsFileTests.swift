import XCTest

@testable import kmap

/// pyhgtmap's login file, written and read back the way ConfigArgParse reads it.
final class ElevationLoginsFileTests: XCTestCase {
    private let awkward = [
        "plain",
        "with # a hash",
        "semi ; colon",
        "a: colon",
        "quote\"inside",
        "\"quoted\"",
        "'single'",
        "  spaces  ",
        "trailing\"",
        "ünïcode пароль"
    ]

    func testEveryWritableValueComesBackAsWritten() {
        for value in awkward {
            XCTAssertTrue(ElevationLogins.isWritable(value), value)
            let text = ElevationLogins.render(["srtm-password": value])
            XCTAssertEqual(ElevationLogins.parse(text)["srtm-password"], value, value)
        }
    }

    func testWhatTheFormatCannotHoldIsRefused() {
        XCTAssertFalse(ElevationLogins.isWritable("two\nlines"))
        XCTAssertFalse(ElevationLogins.isWritable("carriage\rreturn"))
        XCTAssertFalse(ElevationLogins.isWritable("[a list]"))
        XCTAssertTrue(ElevationLogins.isWritable("[half"))
    }

    func testAFileWrittenByHandIsReadAsPyhgtmapReadsIt() {
        let text = """
            # a comment
            ; another
            srtm-user = someone   # a note
            srtm-password: 'secret'
            alos-user "mismatched'
            """
        let values = ElevationLogins.parse(text)
        XCTAssertEqual(values["srtm-user"], "someone")
        XCTAssertEqual(values["srtm-password"], "secret")
        XCTAssertEqual(values["alos-user"], "\"mismatched'")
    }
}
