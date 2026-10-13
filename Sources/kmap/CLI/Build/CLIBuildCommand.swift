import Foundation

/// `kmap build`: the whole pipeline from one command line. Every flag the interactive form
/// offers has an equivalent here. The order is fixed: read the profile, let the flags
/// override it, refuse everything wrong at once, then hand a recipe to the pipeline.
extension CLI {
    static func regionRefusal(_ flags: Flags, arguments: [String]) -> String? {
        guard flags.positionals.count != 1 else { return nil }
        guard let second = flags.positionals.dropFirst().first else {
            return "build needs a region id, e.g. austria"
        }
        // A mistyped option leaves its value standing alone, where it reads as a region.
        let unknown = unknownBuildOptions(in: flags)
        guard unknown.isEmpty else {
            return unknown.map { "--\($0) is not an option of `kmap build` — see `kmap help`" }
                .joined(separator: "; ")
        }
        // A value given after a space to an `=`-only option, before or after the region.
        for (at, word) in arguments.enumerated().dropFirst() where flags.positionals.contains(word) {
            let before = arguments[at - 1]
            if valuedOnlyAfterEquals.map({ "--" + $0 }).contains(before) {
                return "\"\(word)\" follows \(before), which takes a value only after =,"
                    + " as \(before)=\(word); several regions are joined with +"
            }
        }
        return "build takes one region id, and \"\(second)\" is a second;"
            + " several regions are joined with +, e.g. austria+germany"
    }

    static func build(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: buildValuedOptions)
        if let refusal = regionRefusal(flags, arguments: arguments) { return CLIOutput.refuse(refusal) }
        let regionID = flags.positionals[0]

        // Flags apply to this run only: a one-off `--out=` must not become the stored
        // output folder.
        let store = SettingsStore()
        store.overrideForRun { settings in
            if flags.has("keep-work") { settings.keepWorkFiles = true }
            if let out = flags.value("out") { settings.outputDirectory = out }
            if let work = flags.value("work") { settings.workDirectory = work }
        }
        let toolchain = Toolchain(settings: store)
        let catalog = StyleCatalog(settings: store, toolchain: toolchain)

        guard let choices = chosenChoices(flags.value("profile"), in: store) else {
            return CLIOutput.refuse("no profile called \"\(flags.value("profile") ?? "")\" — see `kmap profiles`")
        }

        var asked = BuildOptions(flags)
        for name in unknownBuildOptions(in: flags) {
            asked.refused.append("--\(name) is not an option of `kmap build` — see `kmap help`")
        }
        guard let request = BuildRequest(&asked, choices: choices, store: store, catalog: catalog) else {
            return CLIOutput.refuse(asked.refused)
        }

        // The network is reached only after every flag has been accepted.
        let index = RegionIndex()
        do {
            try await index.load()
        } catch {
            return CLIOutput.failure("\(error.localizedDescription)")
        }
        let chosen: [Region]
        switch chosenRegions(regionID, in: index) {
        case .success(let found): chosen = found
        case .failure(let refusal): return CLIOutput.refuse(refusal.why)
        }
        let recipe = request.recipe(for: chosen, in: index)

        // Said before any work starts, naming the one command that fixes it.
        guard toolchain.canBuild else {
            let missing = Toolchain.missingRequirements(in: toolchain.status()).map(\.id)
            return CLIOutput.refuse("\(missing.joined(separator: " and ")) missing — run: kmap install")
        }

        let pipeline = BuildPipeline(
            recipe: recipe,
            settings: store,
            toolchain: toolchain,
            styles: catalog,
            showing: CLIOutput.showing
        )
        // Ctrl+C cancels the pipeline, so its tools stop and the stream ends with its last
        // event; watched before the first tool can start.
        let interrupts = watchInterrupts { pipeline.cancel() }
        defer { interrupts.stop() }
        pipeline.start()
        return await follow(pipeline, landingIn: recipe.destinationDirectory)
    }
}
