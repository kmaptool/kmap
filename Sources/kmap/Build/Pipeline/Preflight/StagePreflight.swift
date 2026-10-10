import Foundation

/// Stage 1: the recipe and the toolchain checked before anything is downloaded.
extension BuildPipeline {
    // MARK: 1 - preflight

    /// A family id given by hand is stored for this map, so the allocator gives it to no
    /// other. One another map holds is warned of: the 2 hide each other on a device.
    private func keepFamilyID() {
        let key = BuildRecipe.identityKey(recipe.regions)
        let id = recipe.familyID
        // A reserved id serves this run only: stored, the next build would move it again
        // and ask to remove the copy just made. A pending move note waits for a build on
        // the map's own id.
        if BuildRecipe.reservedFamilyIDs.contains(id) {
            log.warn("family id \(id) is mkgmap's own default: a map another tool built with it hides this one")
            return
        }
        // Warned of too: a stored reserved id the form replaced without saying so.
        let stored = settings.settings.familyIDs[key]
        let replaced = stored.flatMap { BuildRecipe.reservedFamilyIDs.contains($0) && $0 != id ? $0 : nil }
        if let old = settings.movedFamilyID(for: key) ?? replaced {
            log.warn(
                "family id \(old) is mkgmap's own default, shared with maps other tools build:"
                    + " this map is \(id) from now on — remove its old copy from the device"
            )
            settings.update { $0.movedFamilyIDs[key] = nil }
        }
        guard settings.settings.familyIDs[key] != id else { return }
        // Read again under the file's lock: another kmap may have given the id out since.
        var other: String?
        settings.update { settings in
            other = settings.familyIDs.first { $0.key != key && $0.value == id }?.key
            settings.familyIDs[key] = id
        }
        if let other { log.warn("family id \(id) is also the map of \(other)'s: a device shows only 1 of the 2") }
    }

    func preflight() async throws {
        set(.preflight, .running, t("checking tools"))
        log.step("preparing")
        try checkRecipe()
        try await checkTools()

        Paths.bootstrap()
        try clearEarlierWork()
        // The destination is made at the end, so a failed build leaves no empty folder.

        warnOfLowSpace()
        logRecipe()
        sweepUnfinishedDownloads()
        // Packs sit in the toolchain for months; 1 HEAD each says if the mirror moved on.
        await checkDataPacks()
        set(.preflight, .done, t("ready"))
    }

    /// What mkgmap would stop on only at the compile, checked before the download; a
    /// family id that passes is stored for the map unless reserved.
    func checkRecipe() throws {
        guard CodePage.mkgmapTakes.contains(recipe.codePage) else { throw BuildError.unknownCodePage(recipe.codePage) }
        guard BuildRecipe.familyIDRange.contains(recipe.familyID) else {
            throw BuildError.familyIDOutOfRange(recipe.familyID)
        }
        keepFamilyID()
    }

    /// Also renews a stale mkgmap patch.
    func checkTools() async throws {
        guard toolchain.findJava() != nil else {
            throw BuildError.missingTool("Java — install it with: " + Platform.installHint(.java))
        }
        guard toolchain.findMkgmap() != nil else {
            throw BuildError.missingTool("mkgmap — install it from the Toolchain screen")
        }
        if toolchain.patchIsStale {
            detail(.preflight, t("rebuilding the mkgmap patch"))
            let older = Toolchain.patchState(of: Toolchain.patchedMkgmapURL).version < Toolchain.patchVersion
            log.step(
                older
                    ? "the mkgmap patch is from an older kmap, rebuilding it"
                    : "the mkgmap patch is built for a newer Java than this one, rebuilding it"
            )
            if await toolchain.renewStalePatch(log: log) {
                log.ok("the mkgmap patch is rebuilt")
            } else {
                log.warn("building without the patch, as with the stock mkgmap")
            }
        }
        // Only sources that need an account go through pyhgtmap.
        if recipe.needsElevationData, !credentialedSources.isEmpty,
            toolchain.findPyhgtmap() == nil
        {
            throw BuildError.missingTool(
                "pyhgtmap — needed for \(credentialedSources.joined(separator: ", "))."
                    + " Install it from the Toolchain screen, or pick copernicus, fabdem, gedtm or view1/view3"
            )
        }
    }

    func warnOfLowSpace() {
        // The work folder takes the most, the cache the downloads, the output the map. Once
        // per volume: on macOS each answer is a round trip to a system service.
        var asked: Set<String> = []
        for folder in [workDirectory, Paths.root, Self.nearestPresent(recipe.destinationDirectory)] {
            if let volume = FileTools.volume(of: folder), !asked.insert(volume).inserted { continue }
            let free = FileTools.freeSpaceBytes(at: folder)
            guard free > 0, free < 8_000_000_000 else { continue }
            log.warn(
                "only \(Fmt.bytes(free)) free on the volume holding \(Paths.display(folder)) — large regions may not fit"
            )
        }
    }

    func logRecipe() {
        log.append("region:  \(recipe.mapName)  [\(recipe.regions.map(\.id).joined(separator: ", "))]")
        log.append("bbox:    \(recipe.coverage.display)")
        log.append(
            "style:   \(recipe.style.name) · code page \(recipe.codePage)"
                + (recipe.effectiveNameTagList.isEmpty ? "" : " · labels \(recipe.effectiveNameTagList)")
        )
        if recipe.codePage == CodePage.westernEuropean, recipe.coverage.isValid,
            recipe.coverage.minLon > CodePage.cyrillicMeridian
        {
            log.warn(
                "code page 1252 cannot hold Cyrillic — names would be transliterated to Latin."
                    + " Set 1251 if this region's names are in Cyrillic."
            )
        }
        log.append("product: family \(recipe.familyID) · tiles from \(recipe.mapIDBase)")
        log.append(
            "options: contours=\(recipe.contours ? "\(recipe.contourInterval) m" : "off")"
                + "  dem=\(recipe.demLayer ? "on" : "off")"
                + "  routable=\(recipe.routable)  index=\(recipe.searchIndex)"
        )
        if recipe.houseNumbers, !recipe.searchIndex {
            log.append("house numbers left out: they are found only through the search index, which is off")
        }
        log.append("levels:  \(recipe.levels.name) — \(recipe.levels.levels)")
        log.append("work:    \(Paths.display(workDirectory))")
        log.append("output:  \(recipe.splitMode.label) → \(Paths.display(recipe.destinationDirectory))")
    }

    /// Nothing else removes these parts; a half-fetched data pack in tools is the largest.
    func sweepUnfinishedDownloads() {
        // In caches only kmap's own names at the top: a cache may be the person's folder.
        let folders =
            CacheClearing.folders(Paths.hgtCache, elevation: true)
            + CacheClearing.folders(Paths.pbfCache, elevation: false)
        let freed =
            folders.reduce(Int64(0)) { sum, entry in
                sum
                    + PartFiles.sweepAbandoned(in: entry.folder, topOnly: true) {
                        CacheClearing.isOwn($0, in: entry.kind)
                    }
            }
            + PartFiles.sweepAbandoned(in: Paths.tools)
        if freed > 0 {
            log.append("cleared \(Fmt.bytes(freed)) left by downloads that were never finished")
        }
    }
}
