import CVector

/// Runs a check at every tier of vector code this machine has, the lowest being none
/// at all, and leaves the machine's own tier in force afterwards.
///
/// On x86 that is SSE4.1, SSSE3, SSE2 and none; on ARM, NEON and none.
enum VectorTiers {
    /// Above any tier there is, so limiting to it limits nothing.
    private static let unlimited: Int32 = 3

    static func each(_ body: (_ tier: Int32) -> Void) {
        defer { _ = kmap_vector_limit(unlimited) }
        var seen = Set<Int32>()
        for most in (0...unlimited).reversed() {
            let tier = kmap_vector_limit(most)
            if seen.insert(tier).inserted { body(tier) }
        }
    }
}
