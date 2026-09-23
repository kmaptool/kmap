import Foundation

/// `kmap embed-assets`: Assets/ folded back into StyleAssets.swift. The generated file is
/// committed source, so a build needs nothing but `swift build`.
extension CLI {
    static func embedAssets(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["assets", "out"])
        let root = URL(fileURLWithPath: flags.value("assets") ?? AssetEmbedder.defaultRoot)
        let out = URL(fileURLWithPath: flags.value("out") ?? AssetEmbedder.defaultOutput)
        do {
            let text = try AssetEmbedder.render(from: root)
            try FileTools.write(text, to: out)
            CLILog.line(t("wrote %@ (%@)", out.path, Fmt.bytes(Int64(text.utf8.count))))
            CLIOutput.result(["out": .string(out.path), "bytes": .int(text.utf8.count)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }
}
