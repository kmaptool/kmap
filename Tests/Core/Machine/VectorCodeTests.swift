import CVector
import XCTest

@testable import kmap

/// The name `kmap doctor` gives the vector code in use: an instruction set this
/// architecture has, at every tier the machine allows.
final class VectorCodeTests: XCTestCase {
    func testEveryTierHereIsNamedByAnInstructionSetOfThisArchitecture() {
        #if arch(arm64)
        let sets = ["none", "NEON"]
        #else
        let sets = ["none", "SSE2", "SSSE3", "SSE4.1", "AVX2"]
        #endif
        VectorTiers.each { tier in
            XCTAssertTrue(sets.contains(VectorCode.name), "tier \(tier): \(VectorCode.name)")
            XCTAssertEqual(VectorCode.name, VectorCode.name(ofTier: Int(tier)))
        }
    }

    func testNoVectorCodeIsSaidSo() {
        XCTAssertEqual(VectorCode.name(ofTier: 0), "none")
    }

    func testTheWidestX86TierIsAVX2() {
        XCTAssertEqual(VectorCode.name(ofTier: 4), "AVX2")
    }
}
