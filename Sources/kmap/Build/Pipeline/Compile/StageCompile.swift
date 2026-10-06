import Foundation

/// Stage 5: mkgmap, over every tile in one run.
extension BuildPipeline {
    // MARK: 5 - compile

    /// Prepares the style and copies it for this build, checking the copy is what was
    /// prepared: another build with other choices may swap the shared rules in between,
    /// and this one would compile its hides and zoom plan.
    private func prepareStyleSnapshot(runner: ProcessRunner) async throws {
        let choices = StyleChoices(
            descriptions: recipe.descriptions,
            hidden: recipe.hidden,
            zoom: (recipe.zoomPlan, recipe.levels),
            cyrillic: recipe.speaksRussian
        )
        let mine = workDirectory.appendingPathComponent("style", isDirectory: true)
        FileTools.removeIfPresent(mine)
        var missing: URL?
        for _ in 0..<Self.styleSnapshotTries {
            try await styles.prepare(
                recipe.style,
                log: log,
                runner: runner,
                descriptions: choices.descriptions,
                hidden: choices.hidden,
                zoom: choices.zoom,
                cyrillicLabels: choices.cyrillic
            )
            guard let shared = recipe.style.styleDirectory else { return }
            // Rules prepared a moment ago and gone, mid-swap by another build, would compile
            // as mkgmap's own style with nothing said.
            guard FileTools.exists(shared) else {
                // Only kmap's own rules come back with another prepare.
                if case .customDirectory = recipe.style.origin {
                    throw BuildError.styleFolderGone(Paths.display(shared))
                }
                missing = shared
                continue
            }
            missing = nil
            let expected = styles.expectedMarker(for: recipe.style, choices: choices)
            // A copy that fails, on a full disk say, fails the build: the shared rules are
            // not this build's to read while another may rewrite them.
            if try styles.snapshot(shared, to: mine, expecting: expected) { return }
            log.append("another build changed the shared style meanwhile — preparing it again")
        }
        // Rules that never came, as a recovered style's whose sheet will not read, are gone,
        // not changed.
        if let missing { throw BuildError.styleFolderGone(Paths.display(missing)) }
        throw BuildError.styleKeptChanging
    }

    private static let styleSnapshotTries = 3

    func compile(tiles: TileSet) async throws {
        set(.compile, .running, t("preparing style"))
        let runner = makeRunner()
        try await prepareStyleSnapshot(runner: runner)

        // The repair pass emits two types no borrowed style defines, so they are added to
        // a copy of the TYP in this build's scratch. The user's own file is never written.
        let typ = TypAugment.prepare(
            recipe.style.typURL,
            theme: recipe.theme,
            into: recipe.workDirectory.appendingPathComponent("typ", isDirectory: true),
            rules: recipe.style.styleDirectory,
            // Only with the mkgmap that hands the copies out: a copy nothing is typed as
            // costs nothing, but there is no call to add it.
            liftingOpenGround: toolchain.mkgmapIsPatched
        )
        if let typ {
            // The device reads the TYP's names in the TYP's own code page: in another than
            // the map's, the names of its kinds of thing come out garbled. mkgmap compiles a
            // text TYP in the map's page; a compiled one keeps its own.
            if let info = TypInfo.read(typ.url), info.isBinary, let page = info.codePage, page != recipe.codePage {
                log.warn(
                    "\(typ.url.lastPathComponent) is written in code page \(page), the map in"
                        + " \(recipe.codePage) — the device may show its names garbled"
                )
            }
            for added in typ.added { log.append("added to the TYP for this build: \(added)") }
            if let note = typ.theme { log.append("TYP: " + note) }
            if let refusal = typ.refusal { log.warn(refusal) }
            if typ.shapeLift != nil {
                log.append("TYP: open ground lying on a larger wood is drawn over it, for this build")
            }
            if typ.woodsLaidOver {
                log.append("TYP: woods drawn over the settlement tints, and those over open ground, for this build")
            }
            // A mark that had to move takes its rules with it, or the repair links
            // would still be emitted under the number the borrowed style draws. The
            // rules are moved in this build's own snapshot of the style, never in the
            // shared copy: another style built next may keep the original number.
            repairMoves = typ.moved
        }

        guard let java = toolchain.findJava(),
            let mkgmap = toolchain.findMkgmap()?.url
        else {
            throw BuildError.missingTool("mkgmap")
        }
        if recipe.demLayer { await writeDEMPolygon() }

        // Every tile in one run, each to an .img of its own. Which output file a tile goes
        // in is settled afterwards by weighing them, since size cannot be predicted.
        let tileDir = workDirectory.appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("tiles", isDirectory: true)
        FileTools.removeIfPresent(tileDir)
        Paths.ensure(tileDir)

        let argsFile = tileDir.appendingPathComponent("tiles.args")
        let args = "# generated by kmap\n" + tiles.tiles.map(\.argsBlock).joined(separator: "\n\n") + "\n"
        try FileTools.write(args, to: argsFile)

        // The JVM starts warm from the cache an earlier compile left, or records one.
        var warm = JavaWarmStart.plan(java: java, jar: mkgmap, heapGB: recipe.heapGB, recording: true)
        for stale in JavaWarmStart.leftovers(keeping: warm.cache) { FileTools.removeIfPresent(stale) }
        if warm.recording != nil {
            // A JVM that cannot record fails the run it records in, where reading a cache never
            // does: asked first with a run that does nothing, and not asked again for a while.
            if try await canRecord(warm, java: java, mkgmap: mkgmap) {
                log.append("recording a warm start for mkgmap: this compile is slower, the next ones faster")
            } else {
                if refuseUnlessShortOfRoom(warm) {
                    log.append("this Java does not record a warm start for mkgmap; compiling without one")
                }
                JavaWarmStart.discard(warm)
                warm = JavaWarmStart.Plan(cache: warm.cache)
            }
        }
        let rest =
            try mkgmapOptions(
                name: recipe.areaSlug,
                outputDir: tileDir,
                tileCount: tiles.tiles.count,
                gmapsupp: false,
                typ: typ?.url,
                shapeLift: typ?.shapeLift
            ) + ["-c", argsFile.path]
        func command(_ warmOptions: [String]) -> [String] {
            java.command(warmOptions + ["-Xmx\(recipe.heapGB)g", "-jar", mkgmap.path]) + rest
        }
        let arguments = command(warm.options)

        log.step("compiling \(tiles.tiles.count) tile(s)")
        // The exact invocation, so a verbose log alone says what the pipeline decided.
        log.debug(
            "mkgmap " + arguments.drop { $0 != mkgmap.path }.dropFirst().joined(separator: " "),
            stage: StageID.compile.rawValue
        )
        detail(.compile, "starting", fraction: 0)

        let compiled: (missingElevation: Set<String>, recordingFailed: Bool)
        do {
            compiled = try await runMkgmapCompile(
                java: java,
                arguments: arguments,
                tileDir: tileDir,
                tileIDs: tiles.tiles.map(\.mapID),
                nodeCap: tiles.nodeCap,
                recording: warm.recording != nil
            )
        } catch {
            // A compile that failed or was stopped leaves its recording, tens of MB.
            JavaWarmStart.discard(warm)
            throw error
        }
        let missingElevation = compiled.missingElevation
        if compiled.recordingFailed {
            // Every tile was written and only the JVM's exit failed: the recording, not the map.
            JavaWarmStart.refuse(warm)
            JavaWarmStart.discard(warm)
            log.warn("mkgmap wrote every tile, but its JVM could not keep the warm start it recorded")
        }
        await keepWarmStart(warm, java: java, mkgmap: mkgmap)
        if !missingElevation.isEmpty {
            log.append(
                tn(
                    "%d elevation cell(s) beyond the region's outline have no data —"
                        + " the relief there reads as sea level, and so does the map",
                    missingElevation.count
                )
            )
        }

        let files = try await measure(.compile, "write the output files") {
            try await bundle(
                tiles.tiles,
                from: tileDir,
                java: java,
                mkgmap: mkgmap,
                typ: typ?.url
            )
        }
        set(.compile, .done, "\(files) file(s) built")
    }

    /// Marks this Java as one that does not record, for a while. Not where the disk is
    /// all but full: that is the likelier cause, and says nothing of the Java.
    /// - Returns: whether it was marked.
    private func refuseUnlessShortOfRoom(_ warm: JavaWarmStart.Plan) -> Bool {
        guard let cache = warm.cache else { return false }
        let free = FileTools.freeSpaceBytes(at: Self.nearestPresent(cache))
        if free > 0, free < 2_000_000_000 {
            log.append("only \(Fmt.bytes(free)) free for mkgmap's warm start; compiling without one this time")
            return false
        }
        JavaWarmStart.refuse(warm)
        return true
    }

    /// Makes the cache out of what a recording compile wrote. The cache lands under its
    /// name only whole; a failure here costs the warm start and not the build.
    private func keepWarmStart(_ warm: JavaWarmStart.Plan, java: JavaRuntime, mkgmap: URL) async {
        guard let recording = warm.recording, let cache = warm.cache else { return }
        let pending = JavaWarmStart.pending(for: recording)
        defer { JavaWarmStart.discard(warm) }
        guard FileTools.exists(recording),
            let options = JavaWarmStart.assembly(warm, jar: mkgmap, heapGB: recipe.heapGB)
        else { return }
        let made = try? await makeRunner().run(java.path, java.command(options), allowFailure: true) { _ in }
        // A JVM that failed may have left a part of the cache: it does not take the name, and
        // is not asked to record again for a while.
        guard made?.exitCode == 0, FileTools.size(of: pending) > 0 else {
            guard !isCancelled, refuseUnlessShortOfRoom(warm) else { return }
            log.warn("mkgmap's warm start could not be made from what was recorded; compiling without one for now")
            return
        }
        // Another build recording at the same time may have put its cache there first.
        if !FileTools.exists(cache) { try? FileTools.move(pending, to: cache) }
        guard FileTools.exists(cache) else { return }
        log.append("mkgmap starts warm from now on (\(Fmt.bytes(FileTools.size(of: cache))) kept in the cache)")
    }

    /// Runs the one mkgmap invocation that compiles every tile, polling the directory
    /// for finished .img files since mkgmap reports no per-tile progress. An overflowing
    /// tile fails the stage with the ids to cut finer.
    ///
    /// - Returns: elevation cells mkgmap reported missing. Elevation is fetched for the
    ///   region's outline while mkgmap builds relief for the whole rectangle, so cells in
    ///   between are reported missing: counted, not logged.
    private func runMkgmapCompile(
        java: JavaRuntime,
        arguments: [String],
        tileDir: URL,
        tileIDs: [String],
        nodeCap: Int,
        recording: Bool
    ) async throws -> (missingElevation: Set<String>, recordingFailed: Bool) {
        // The last tenth of the bar is the bundling that follows.
        let board = board
        let watcher = Task {
            while !Task.isCancelled {
                let done = tileIDs.filter {
                    FileTools.exists(tileDir.appendingPathComponent("\($0).img"))
                }.count
                board.detail(
                    .compile,
                    "\(done)/\(tileIDs.count) tile(s)",
                    fraction: min(0.88, Double(done) / Double(max(1, tileIDs.count)) * 0.9)
                )
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { watcher.cancel() }
        let compileRunner = makeRunner()
        var overflowed = false
        var failedIDs: [Int] = []
        var missingElevation: Set<String> = []
        var finishedCleanly = false
        var outOfMemory = false
        let lock = NSLock()
        do {
            _ = try await measure(.compile, "mkgmap") {
                try await compileRunner.run(java.path, arguments, cwd: tileDir) { line in
                    if line.contains("HGTReader") && line.contains("not found") {
                        if let cell = line.range(
                            of: #"[NS]\d{2}[EW]\d{3}"#,
                            options: .regularExpression
                        ) {
                            lock.lock()
                            missingElevation.insert(String(line[cell]))
                            lock.unlock()
                        }
                        return
                    }
                    if JavaWarmStart.isOwnRemark(line) { return }
                    self.log.output(line, stage: StageID.compile.rawValue)
                    if Self.isCleanFinish(line) {
                        lock.lock()
                        finishedCleanly = true
                        lock.unlock()
                    }
                    // Said only in the log otherwise, behind a stack trace.
                    if line.contains("java.lang.OutOfMemoryError") {
                        lock.withLock { outOfMemory = true }
                    }
                    // mkgmap names the overflowing tile and exits; the run loop cuts it finer.
                    if line.contains("RGN section") && line.contains("too big") {
                        lock.lock()
                        overflowed = true
                        if let match = line.range(
                            of: #"(\d{8})\.osm\.pbf"#,
                            options: .regularExpression
                        ),
                            let id = Int(line[match].prefix(8))
                        {
                            failedIDs.append(id)
                        }
                        lock.unlock()
                    }
                }
            }
        } catch {
            if overflowed { throw BuildError.tileTooDense(nodeCap, failed: failedIDs) }
            if lock.withLock({ outOfMemory }) { throw BuildError.javaOutOfMemory(recipe.heapGB) }
            // A recording JVM writes what it recorded as it exits, after mkgmap is done: a
            // failure there fails only the exit. mkgmap said it finished without a failure,
            // since a tile's .img is there from the moment it is begun.
            if recording, case ProcessRunner.RunError.failed = error, lock.withLock({ finishedCleanly }),
                tileIDs.allSatisfy({ ImgContainer.isWhole(tileDir.appendingPathComponent("\($0).img")) })
            {
                return (missingElevation, true)
            }
            throw error
        }
        if overflowed { throw BuildError.tileTooDense(nodeCap, failed: failedIDs) }
        return (missingElevation, false)
    }

    /// Whether this JVM records a warm start for mkgmap: the same options on a run that only
    /// prints mkgmap's version. A JVM that refuses them, or cannot write what it recorded,
    /// says so here and not after a whole compile.
    /// A stop during the run is thrown, not taken for a refusal.
    private func canRecord(_ warm: JavaWarmStart.Plan, java: JavaRuntime, mkgmap: URL) async throws -> Bool {
        guard let probe = JavaWarmStart.probe(warm, jar: mkgmap, heapGB: recipe.heapGB) else { return false }
        defer { FileTools.removeIfPresent(probe.recording) }
        let ran = try? await makeRunner().run(java.path, java.command(probe.options), allowFailure: true) { _ in }
        try stopIfCancelled()
        return ran?.exitCode == 0 && FileTools.size(of: probe.recording) > 0
    }

    /// The line mkgmap ends a run with when no map failed: printed after the last tile is
    /// written, and only then.
    static func isCleanFinish(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Number of ExitExceptions: 0")
    }
}
