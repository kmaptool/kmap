import CVector
import XCTest

@testable import kmap

/// Contour cells marked a vector at a time match the plain loop, at every tier here.
final class ContourCellsTests: XCTestCase {
    private let floor: Int16 = -32768

    private func plainMarks(_ top: [Int16], _ bottom: [Int16], _ bandTop: [Int32], _ bandBottom: [Int32]) -> [UInt64] {
        let cells = top.count - 1
        var marks = [UInt64](repeating: 0, count: (cells + 63) / 64)
        for c in 0..<cells {
            let ground = [top[c], top[c + 1], bottom[c], bottom[c + 1]].allSatisfy { $0 > floor }
            let b = bandTop[c]
            let spans = bandTop[c + 1] != b || bandBottom[c] != b || bandBottom[c + 1] != b
            if ground && spans { marks[c / 64] |= 1 << UInt64(c % 64) }
        }
        return marks
    }

    func testEveryTierMarksWhatThePlainLoopMarks() {
        var random = SplitMix64(state: 20_261_007)
        // Around each vector width and past it, so every tail length is met.
        for cells in Array(1...70) + [127, 128, 129, 255, 1000] {
            for round in 0..<6 {
                // A few levels, so bands repeat; a void now and then, the floor itself.
                let samples = cells + 1
                func row() -> [Int16] {
                    (0..<samples).map { _ in
                        random.next() % 9 == 0 ? floor : Int16(truncatingIfNeeded: Int(random.next() % 7) * 10 - 20)
                    }
                }
                let top = row()
                let bottom = round == 0 ? top : row()
                let bandTop = top.map { Int32($0 / 10) }
                let bandBottom = bottom.map { Int32($0 / 10) }
                let expected = plainMarks(top, bottom, bandTop, bandBottom)
                VectorTiers.each { tier in
                    var marks = [UInt64](repeating: 0, count: (cells + 63) / 64)
                    kmap_contour_cells(top, bottom, bandTop, bandBottom, cells, floor, &marks)
                    XCTAssertEqual(marks, expected, "\(cells) cells, round \(round), tier \(tier)")
                }
            }
        }
    }

    /// Bands far apart in their high bits: equality is asked of all 32, not a narrowed copy.
    func testBandsThatDifferOnlyHighUpStillSpan() {
        let cells = 40
        let top = [Int16](repeating: 5, count: cells + 1)
        let bandTop = (0...cells).map { $0 % 3 == 0 ? Int32(1 << 20) : 0 }
        let bandBottom = [Int32](repeating: 0, count: cells + 1)
        let expected = plainMarks(top, top, bandTop, bandBottom)
        XCTAssertNotEqual(expected, [0])
        VectorTiers.each { tier in
            var marks = [UInt64](repeating: 0, count: 1)
            kmap_contour_cells(top, top, bandTop, bandBottom, cells, floor, &marks)
            XCTAssertEqual(marks, expected, "tier \(tier)")
        }
    }
}
