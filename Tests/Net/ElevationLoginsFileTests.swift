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

    /// A quote, a space and a comment sign would end the value early.
    func testAValueTheReaderWouldCutShortIsRefused() {
        for value in ["ab\" #cd", "ab\" ;cd", "a\" # b\"c", "x\"\t#y"] {
            XCTAssertFalse(ElevationLogins.isWritable(value), value)
        }
        // The same signs without the quote before them are held.
        for value in ["pa #ss", "pa ;ss", "ab\"#cd", "#lead", "\""] {
            XCTAssertTrue(ElevationLogins.isWritable(value), value)
            XCTAssertEqual(ElevationLogins.parse(ElevationLogins.render(["k": value]))["k"], value, value)
        }
        XCTAssertTrue(ElevationLogins.isWritable(""), "an empty value is a key left out")
    }

    // MARK: Changing pyhgtmap's own file

    /// Only the login's lines change.
    func testALoginIsChangedInPlaceAndTheRestIsLeftAlone() {
        let text = """
            # my notes
            hgtdir = /data/hgt   # where tiles go
            srtm-user: old
            no-zero-contour
            srtm-password: 'secret'

            ; the end

            """
        let changed = ElevationLogins.updating(text, with: ["srtm-user": "new", "srtm-password": "pa ss"])
        XCTAssertEqual(
            changed,
            """
            # my notes
            hgtdir = /data/hgt   # where tiles go
            srtm-user: "new"
            no-zero-contour
            srtm-password: "pa ss"

            ; the end

            """
        )
    }

    func testAKeyNotThereIsAddedAtTheEndAndAnEmptiedOneTakenOut() {
        let text = "# notes\nalos-user: someone\nsrtm-user: gone\n"
        let changed = ElevationLogins.updating(
            text,
            with: ["srtm-user": "", "srtm-password": "x", "alos-password": "y"]
        )
        XCTAssertEqual(changed, "# notes\nalos-user: someone\nalos-password: \"y\"\nsrtm-password: \"x\"\n")
        // A file with no line break at its end gets one before what is added.
        XCTAssertEqual(
            ElevationLogins.updating("hgtdir = /d", with: ["srtm-user": "u"]),
            "hgtdir = /d\nsrtm-user: \"u\"\n"
        )
    }

    /// A note after a login stays on its line, unless the value would then read back wrong.
    func testTheCommentAfterAChangedLoginIsKept() {
        let text = "srtm-user = someone   # my work account\nsrtm-password: old ; rotate in May\n"
        let changed = ElevationLogins.updating(text, with: ["srtm-user": "other", "srtm-password": "new"])
        XCTAssertEqual(
            changed,
            "srtm-user: \"other\"  # my work account\nsrtm-password: \"new\"  # rotate in May\n"
        )
        let read = ElevationLogins.parse(changed)
        XCTAssertEqual(read["srtm-user"], "other")
        XCTAssertEqual(read["srtm-password"], "new")
    }

    func testANewFileIsWhatRenderWrites() {
        let values = ["srtm-user": "someone", "srtm-password": "secret"]
        XCTAssertEqual(ElevationLogins.updating("", with: values), ElevationLogins.render(values))
    }

    /// A repeated key keeps 1 line, and CRLF endings stay.
    func testARepeatedKeyIsLeftOnceAndCarriageReturnsAreKept() {
        let text = "srtm-user: a\r\n# note\r\nsrtm-user = b\r\n"
        let changed = ElevationLogins.updating(text, with: ["srtm-user": "c", "srtm-password": "p"])
        XCTAssertEqual(changed, "srtm-user: \"c\"\r\n# note\r\nsrtm-password: \"p\"\r\n")
        XCTAssertEqual(ElevationLogins.parse(changed)["srtm-user"], "c")
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
