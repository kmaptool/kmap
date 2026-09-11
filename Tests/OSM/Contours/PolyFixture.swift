import Foundation

/// Outlines the tests read: a square degree, 10..11 E, 40..41 N.
enum PolyFixture {
    static let square = """
    test-region
    1
       10.0  40.0
       11.0  40.0
       11.0  41.0
       10.0  41.0
       10.0  40.0
    END
    END
    """
}
