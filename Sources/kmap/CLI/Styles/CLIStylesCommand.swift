import Foundation

/// `kmap styles`: what `--style` can name.
extension CLI {
    /// The id column, capped so one long id does not push every name off to the right.
    private static let styleIDColumnLimit = 46

    static func listStyles() -> Int32 {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        let styles = catalog.availableStyles()
        let width = min(styleIDColumnLimit, styles.map(\.id.count).max() ?? 20)
        for style in styles {
            let id =
                style.id.count >= width
                ? style.id
                : style.id.padding(toLength: width, withPad: " ", startingAt: 0)
            CLILog.line("\(id)  \(style.name)")
            CLILog.line("\(String(repeating: " ", count: width + 2))\(style.summary)")
        }
        CLILog.line("\n\(styles.count) style(s)")
        CLIOutput.result([
            "styles": .array(
                styles.map {
                    [
                        "id": .string($0.id), "name": .string($0.name),
                        "summary": .string($0.summary), "origin": .string($0.origin.name),
                        "familyID": .int($0.familyID), "productID": .int($0.productID),
                        "typ": .of($0.typURL?.path)
                    ]
                }
            )
        ])
        return 0
    }
}
