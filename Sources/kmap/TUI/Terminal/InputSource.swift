import Foundation

/// Where key bytes come from: the console in the app, and a written script in a test.
protocol InputSource {
    func wait(milliseconds: Int32) -> Readiness
    func read(into buffer: inout [UInt8]) -> Int
}

struct ConsoleInput: InputSource {
    func wait(milliseconds: Int32) -> Readiness {
        Console.waitForInput(milliseconds: milliseconds)
    }

    func read(into buffer: inout [UInt8]) -> Int { Console.read(into: &buffer) }
}
