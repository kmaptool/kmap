import CVector

/// The vector code this binary runs on this processor, named as the instruction set is.
/// `kmap doctor` shows it, so a timing sent from another machine says which path ran.
enum VectorCode {
    /// The instruction set of a tier `kmap_vector_tier` answers.
    static func name(ofTier tier: Int) -> String {
        switch tier {
        case 1:
            #if arch(arm64)
            return "NEON"
            #else
            return "SSE2"
            #endif
        case 2: return "SSSE3"
        case 3: return "SSE4.1"
        case 4: return "AVX2"
        default: return "none"
        }
    }

    /// The instruction set in use here.
    static var name: String { name(ofTier: Int(kmap_vector_tier())) }
}
