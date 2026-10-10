import XCTest

@testable import kmap

final class TypeNamesTests: XCTestCase {
    func testRowsAreReadByKindAndCodeAndBadRowsLeftOut() {
        let names = TypeNames.parse(
            """
            # a note
            line 0x16|Path|Тропа
            point 0x2a00|Restaurant|Ресторан
            polygon 0X4b|Background|Фон
            line nonsense|A|Б
            line 0x17|Only English
            """
        )
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(names[TypeNames.key(.line, 0x16)]?.russian, "Тропа")
        XCTAssertEqual(names[TypeNames.key(.point, 0x2a00)]?.english, "Restaurant")
        XCTAssertEqual(names[TypeNames.key(.polygon, 0x4b)]?.russian, "Фон")
    }

    /// Every section a shipped TYP draws is named in Russian.
    func testEveryShippedSectionHasARussianName() throws {
        for shipped in StyleCatalog.shippedPalettes {
            let source = TypSource.parse(try StyleCatalog.shippedTypText(of: shipped))
            for section in source.sections {
                let russian = section.lines.contains { number in
                    guard let (key, value) = TypSource.entry(of: source.lines[number]),
                        key.lowercased().hasPrefix("string")
                    else { return false }
                    return TypSource.label(in: value).language == 0x19
                }
                XCTAssertTrue(russian, "\(shipped.id) \(section.kind) 0x\(String(section.code, radix: 16))")
            }
        }
    }
}
