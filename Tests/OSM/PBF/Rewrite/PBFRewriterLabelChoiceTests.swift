import XCTest

@testable import kmap

/// A name the code page cannot draw gives way to the next that reads.
final class PBFRewriterLabelChoiceTests: XCTestCase {
    private let russian = ["name:ru", "name", "int_name", "name:en"]
    private let english = ["name:en", "int_name", "name"]

    private func chosen(_ tags: [(String, String)], _ order: [String], codePage: Int = CodePage.cyrillic) -> String? {
        var tags = tags
        _ = PBFRewriter.chooseReadableName(&tags, order: order, codePage: codePage)
        let taken = order.first { key in tags.contains { $0.0 == key && !$0.1.isEmpty } }
        return tags.first { $0.0 == taken && !$0.1.isEmpty }?.1
    }

    func testAGeorgianNameGivesWayToTheNextThatReads() {
        let river = [("name", "ზოფხიტური"), ("name:en", "Zopkhituri"), ("waterway", "river")]
        XCTAssertEqual(chosen(river, russian), "Zopkhituri")
        XCTAssertEqual(chosen(river, ["name"]), "Zopkhituri")
        XCTAssertEqual(chosen(river, english), "Zopkhituri")
        XCTAssertEqual(chosen(river + [("name:ru", "Зопхитури")], russian), "Зопхитури")
        XCTAssertEqual(chosen([("name", "ზოფხიტური"), ("int_name", "Zopkhituri")], russian), "Zopkhituri")
        // Nothing that reads: left to mkgmap, which transliterates.
        XCTAssertEqual(chosen([("name", "ზოფხიტური")], russian), "ზოფხიტური")
    }

    /// An empty value is no tag: mkgmap drops it, so it is neither taken nor put in place.
    func testAnEmptyValueIsNoName() {
        let village = [("name:ru", ""), ("name", "Nəcəfkəndoba"), ("name:en", "Najafkandoba")]
        XCTAssertEqual(chosen(village, russian), "Najafkandoba")
        var tags = [("name", "Nəcəfkəndoba"), ("int_name", ""), ("name:en", "Najafkandoba")]
        XCTAssertTrue(PBFRewriter.chooseReadableName(&tags, order: ["name"], codePage: CodePage.cyrillic))
        XCTAssertEqual(tags[0].1, "Najafkandoba")
    }

    func testAnEnglishMapKeepsItsEnglishName() {
        let place = [("name", "Երևան"), ("name:en", "Yerevan"), ("int_name", "Erevan")]
        XCTAssertEqual(chosen(place, english), "Yerevan")
        XCTAssertEqual(chosen(place, russian), "Erevan")
    }

    func testASchwaIsNoLetterToDrawIn() {
        let village = [("name", "Nəcəfkəndoba"), ("name:en", "Najafkandoba")]
        XCTAssertEqual(chosen(village, russian), "Najafkandoba")
        XCTAssertEqual(chosen([("name", "Аҟәа"), ("name:ru", "Сухум")], russian), "Сухум")
        XCTAssertEqual(chosen([("name", "Аҟәа"), ("name:en", "Sukhumi")], ["name"]), "Sukhumi")
    }

    func testWhatReadsIsLeftAlone() {
        for name in ["Gołdap", "Hämeenlinna", "Қазақстан", "Ставрополь", "Ёжики", "Фыдджынтӕ"] {
            XCTAssertTrue(PBFRewriter.reads(name, codePage: CodePage.cyrillic), name)
            XCTAssertEqual(chosen([("name", name), ("name:en", "x")], russian), name)
        }
        XCTAssertTrue(PBFRewriter.reads("Αθήνα", codePage: 1253))
        XCTAssertFalse(PBFRewriter.reads("Αθήνα", codePage: CodePage.cyrillic))
        // The page that has the letters reads them.
        XCTAssertEqual(chosen([("name", "قاعة"), ("name:en", "Hall")], ["name"], codePage: CodePage.arabic), "قاعة")
        XCTAssertEqual(chosen([("name", "قاعة"), ("name:en", "Hall")], ["name"]), "Hall")
    }

    /// Wherever names meet other scripts: a hard sign on a Latin map, Abkhaz, Tifinagh, a
    /// name in mathematical letters.
    func testEveryScriptMkgmapCannotDrawGivesWay() {
        XCTAssertEqual(
            chosen([("name", "Объект"), ("name:en", "Object")], ["name"], codePage: CodePage.westernEuropean),
            "Object"
        )
        XCTAssertEqual(chosen([("name", "Объект"), ("name:en", "Object")], russian), "Объект")
        XCTAssertEqual(chosen([("name", "Аԥсны"), ("name:ru", "Абхазия")], ["name", "name:ru"]), "Абхазия")
        XCTAssertEqual(chosen([("name", "ⵜⴰⵎⴰⵣⵉⵖⵜ"), ("int_name", "Tamazight")], ["name"]), "Tamazight")
        XCTAssertEqual(
            chosen([("name", "\u{1D402}\u{1D41A}\u{1D41F}\u{1D41E}"), ("name:en", "Cafe")], ["name"]),
            "Cafe"
        )
    }

    /// Letters mkgmap draws on the page read, though outside its main alphabet: apostrophes
    /// of Belarusian and Uzbek, Latin of African orthographies, Roman numerals, ligatures.
    func testLettersMkgmapDrawsRead() {
        for name in ["Падʼезд да вёскі Прудок", "Халамерʼе", "ШӀуьлгӀахь", "Шӏуьлгӏахь"] {
            XCTAssertTrue(PBFRewriter.reads(name, codePage: CodePage.cyrillic), name)
        }
        for name in ["Oʻahu", "Fargʻona", "Kɔforidua", "Saʿīd", "Louis Ⅳ", "ĳsselmeer", "ﬁord", "Ｔｏｋｙｏ"] {
            XCTAssertTrue(PBFRewriter.reads(name, codePage: CodePage.westernEuropean), name)
        }
        XCTAssertTrue(PBFRewriter.reads("ϵ", codePage: 1253))
        // Symbols are not judged.
        XCTAssertTrue(PBFRewriter.reads("Магазин ₽ √", codePage: CodePage.cyrillic))
    }

    /// Letters the page holds in small but mkgmap draws as capitals it lacks, and marks with
    /// no letter to join, do not read.
    func testCapitalsAndLoneMarksAreJudgedAsDrawn() {
        XCTAssertEqual(chosen([("name", "Ταΰγετος"), ("name:en", "Taygetus")], ["name"], codePage: 1253), "Taygetus")
        XCTAssertFalse(PBFRewriter.reads("Πρωτοΐερος", codePage: 1253))
        XCTAssertFalse(PBFRewriter.reads("Ӛ", codePage: CodePage.cyrillic))
        XCTAssertFalse(PBFRewriter.reads("Aelōn̄ in M̧ajeļ", codePage: CodePage.westernEuropean))
        // Composed first: the same letter either way.
        for page in MkgmapUnreadable.pages.keys {
            for (composed, decomposed) in [("\u{01F0}", "j\u{030C}"), ("\u{00E9}", "e\u{0301}")] {
                XCTAssertEqual(
                    PBFRewriter.reads(composed, codePage: page),
                    PBFRewriter.reads(decomposed, codePage: page),
                    "cp\(page) \(composed)"
                )
            }
        }
        XCTAssertTrue(PBFRewriter.reads("Cafe\u{0301}", codePage: CodePage.westernEuropean))
    }

    /// The look at the bytes says what the letters say, for every letter and page.
    func testTheLookAtTheBytesAgreesWithTheLetters() {
        let scalars =
            (0...0xFFFF).compactMap(Unicode.Scalar.init)
            + stride(from: 0x10000, to: 0x10FFFF, by: 97).compactMap {
                Unicode.Scalar(UInt32($0))
            }
        for page in MkgmapUnreadable.pages.keys.sorted() {
            var wrong: [String] = []
            for scalar in scalars {
                let text = String(scalar)
                if PBFRewriter.reads(text, codePage: page) != PBFRewriter.readsLetterByLetter(text, codePage: page) {
                    wrong.append(String(format: "U+%04X", scalar.value))
                }
            }
            XCTAssertTrue(wrong.isEmpty, "cp\(page): \(wrong.prefix(20))")
        }
    }

    /// The table is what mkgmap's encoder says, where this machine has mkgmap and a JDK whose
    /// Unicode is as new as the one the table was made with. With KMAP_WRITE_TABLE set to a
    /// path, the table found is written there as Swift.
    func testTheTableIsMkgmaps() throws {
        #if os(Windows)
        throw XCTSkip("the generator runs through a Unix class path")
        #else
        let jar = URL(fileURLWithPath: ("~/.kmap/tools/mkgmap/mkgmap.jar" as NSString).expandingTildeInPath)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: jar.path), "no mkgmap.jar on this machine")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("Unreadable.java")
        try FileTools.write(Self.generator, to: source)
        guard let kit = Toolchain(settings: SettingsStore()).findJavaKit() else {
            throw XCTSkip("no JDK on this machine")
        }
        let java = URL(fileURLWithPath: kit.path)
        func run(_ tool: URL, _ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            // A JDK was found: a generator that will not run is a failure, not a skip.
            guard process.terminationStatus == 0 else { throw GeneratorFailed(tool: tool.path) }
            return out
        }
        let javac = java.deletingLastPathComponent().appendingPathComponent("javac")
        _ = try run(javac, ["-nowarn", "-cp", jar.path, "-d", work.path, source.path])
        let listed = try run(java, kit.options + ["-cp", jar.path + ":" + work.path, "Unreadable"])
        var lines = listed.split(separator: "\n")
        let feature = Int(lines.first?.split(separator: " ").last ?? "") ?? 0
        lines.removeFirst()
        try XCTSkipIf(feature < MkgmapUnreadable.java, "Java \(feature) knows an older Unicode than the table's")
        var pages: [Int: [ClosedRange<UInt16>]] = [:]
        for line in lines {
            let parts = line.split(separator: " ")
            let ends = parts[1].split(separator: "-").compactMap { UInt16($0, radix: 16) }
            pages[Int(parts[0]) ?? 0, default: []].append(ends[0]...ends[1])
        }
        if let path = ProcessInfo.processInfo.environment["KMAP_WRITE_TABLE"] {
            try FileTools.write(Self.swift(pages, java: feature), to: URL(fileURLWithPath: path))
        }
        XCTAssertEqual(pages, MkgmapUnreadable.pages, "write it again with KMAP_WRITE_TABLE")
        #endif
    }

    private struct GeneratorFailed: Error {
        let tool: String
    }

    private static func swift(_ pages: [Int: [ClosedRange<UInt16>]], java: Int) -> String {
        func hex(_ value: UInt16) -> String { "0x" + String(format: "%04X", value) }
        var lines = [
            "// Generated by PBFRewriterLabelChoiceTests.testTheTableIsMkgmaps from mkgmap's encoder.", "",
            "/// Per code page, the letters and marks of the Basic Multilingual Plane a map's readers do",
            "/// not read: mkgmap labels them with \"?\" or \"@\", or they are of a script the page is not",
            "/// for. A range may span characters that are not judged.",
            "enum MkgmapUnreadable {",
            "    /// The Java whose Unicode said which characters are letters and of what script.",
            "    static let java = \(java)", "", "    static let pages: [Int: [ClosedRange<UInt16>]] = ["
        ]
        // As swift-format leaves it: no comma after the last of a list.
        let sorted = pages.keys.sorted()
        for page in sorted {
            lines.append("        \(page): [")
            let ranges = pages[page] ?? []
            for range in ranges {
                let comma = range == ranges.last ? "" : ","
                lines.append("            \(hex(range.lowerBound))...\(hex(range.upperBound))" + comma)
            }
            lines.append(page == sorted.last ? "        ]" : "        ],")
        }
        return (lines + ["    ]", "}", ""]).joined(separator: "\n")
    }

    /// Per page, the letters and marks of the Basic Multilingual Plane that do not read:
    /// those mkgmap labels with "?" or "@", capitals as it draws them, and those of a script
    /// the page is not for. Others are not judged and may fall inside a range.
    private static let generator = #"""
        import java.nio.charset.Charset;
        import java.util.Arrays;
        import java.util.EnumSet;
        import uk.me.parabola.imgfmt.app.labelenc.AnyCharsetEncoder;
        import uk.me.parabola.imgfmt.app.labelenc.CodeFunctions;
        import uk.me.parabola.imgfmt.app.labelenc.EncodedText;

        public class Unreadable {
            public static void main(String[] args) {
                String spec = System.getProperty("java.specification.version");
                System.out.println("java " + (spec.startsWith("1.") ? spec.substring(2) : spec));
                for (int page : new int[] {1250, 1251, 1252, 1253, 1254}) {
                    AnyCharsetEncoder encoder = (AnyCharsetEncoder) CodeFunctions.createEncoderForLBL(0, page).getEncoder();
                    encoder.setUpperCase(true);
                    Charset charset = Charset.forName("cp" + page);
                    EnumSet<Character.UnicodeScript> scripts = EnumSet.of(
                        Character.UnicodeScript.LATIN, Character.UnicodeScript.COMMON, Character.UnicodeScript.INHERITED);
                    if (page == 1251) scripts.add(Character.UnicodeScript.CYRILLIC);
                    if (page == 1253) scripts.add(Character.UnicodeScript.GREEK);
                    int start = -1, last = -1;
                    for (int c = 0; c <= 0xFFFF; c++) {
                        if (c >= 0xD800 && c <= 0xDFFF) continue;
                        int type = Character.getType(c);
                        boolean judged = Character.isAlphabetic(c) || type == Character.NON_SPACING_MARK
                            || type == Character.COMBINING_SPACING_MARK || type == Character.ENCLOSING_MARK;
                        if (!judged) continue;
                        boolean reads = scripts.contains(Character.UnicodeScript.of(c));
                        if (reads) {
                            EncodedText text = encoder.encodeText(String.valueOf((char) c));
                            String drawn = new String(Arrays.copyOf(text.getCtext(), text.getLength() - 1), charset);
                            reads = !drawn.contains("?") && !drawn.contains("@");
                        }
                        if (reads) {
                            if (start >= 0) System.out.printf("%d %04X-%04X%n", page, start, last);
                            start = -1;
                        } else {
                            if (start < 0) start = c;
                            last = c;
                        }
                    }
                    if (start >= 0) System.out.printf("%d %04X-%04X%n", page, start, last);
                }
            }
        }
        """#
}
