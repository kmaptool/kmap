import Foundation

extension BuildPipeline {
    /// mkgmap's log of the files it packs, each line indented 2 spaces.
    enum MkgmapFiles {
        static let name = "kmap-files.log"

        static let logging = """
            handlers=java.util.logging.ConsoleHandler
            .level=SEVERE
            java.util.logging.ConsoleHandler.level=WARNING
            java.util.logging.ConsoleHandler.formatter=uk.me.parabola.log.UsefulFormatter
            uk.me.parabola.mkgmap.main.Main.level=INFO
            uk.me.parabola.mkgmap.main.Main.handlers=java.util.logging.FileHandler
            java.util.logging.FileHandler.pattern=\(name)
            java.util.logging.FileHandler.formatter=java.util.logging.SimpleFormatter
            java.util.logging.SimpleFormatter.format=%5$s%n

            """

        static func settings(in workDirectory: URL) -> URL {
            workDirectory.appendingPathComponent("mkgmap-logging.properties")
        }

        /// The JVM option, or none if the file could not be written.
        static func option(in workDirectory: URL) -> [String] {
            let url = settings(in: workDirectory)
            try? FileTools.write(logging, to: url)
            return FileTools.exists(url) ? ["-Dlog.config=\(url.path)"] : []
        }

        /// Files named so far by the run in `directory`.
        static func named(by directory: URL) -> Int {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return 0 }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("  ") }.count
        }

        /// Each file once, each map again for the overview.
        static func mentions(of files: [URL]) -> Int {
            files.count + files.filter { $0.pathExtension.lowercased() == "img" }.count
        }

        static func clear(in directory: URL) {
            FileTools.removeIfPresent(directory.appendingPathComponent(name))
            FileTools.removeIfPresent(directory.appendingPathComponent(name + ".lck"))
        }
    }
}
