import Foundation

/// Reporting on styles, profiles and the TYP files that go with them.
///
/// These read and describe rather than build: what styles exist, what a profile chose,
/// what is inside a TYP, and whether a finished map holds what it claims to.
///
/// Internal rather than private: `run` in CLI.swift dispatches to them, and `private` in
/// Swift does not reach across files.
extension CLI {
    /// Reports what kmap can see inside a Garmin `.img`: its sub-files, and the identity of
    /// the TYP where there is one.
    static func typinfo(_ arguments: [String]) -> Int32 {
        let paths = Flags(arguments).positionals
        guard !paths.isEmpty else {
            return CLIOutput.failure("typinfo needs one or more .img paths", code: 2)
        }
        var maps: [JSONValue] = []
        var unreadable = 0
        for path in paths {
            let url = Paths.expand(path)
            CLILog.line(url.lastPathComponent)
            guard FileTools.exists(url) else {
                CLILog.line("  not found")
                maps.append(["file": .string(url.lastPathComponent), "found": false])
                unreadable += 1
                continue
            }
            guard ImgContainer.isImg(url) else {
                CLILog.line("  not a Garmin IMG")
                maps.append(["file": .string(url.lastPathComponent), "found": true,
                             "isIMG": false])
                unreadable += 1
                continue
            }

            let directory = ImgContainer.directory(of: url)
            let listed = directory.filter { ["TYP", "MDR", "MPS"].contains($0.ext.uppercased()) }
            CLILog.line("  \(directory.count) sub-file(s)")
            for sub in listed {
                CLILog.line("    \(sub.fullName)  \(Fmt.bytes(Int64(sub.size)))  \(sub.blocks.count) block(s)")
            }
            // The zoom ladder, tile by tile: which levels the map holds and at what
            // resolution each draws. Two maps of the same ground can differ only here
            // and look nothing alike when zoomed out.
            var ladders: [String: [(level: Int, resolution: Int, count: Int)]] = [:]
            for tre in directory where tre.ext.uppercased() == "TRE" {
                guard let data = ImgContainer.read(tre, from: url),
                      let tree = try? ImgElements.Tree(data, tile: tre.name) else { continue }
                var seen: [Int: (Int, Int)] = [:]
                for division in tree.subdivisions {
                    var held = seen[division.level] ?? (division.shift, 0)
                    held.1 += 1
                    seen[division.level] = held
                }
                ladders[tre.name] = seen.sorted { $0.key < $1.key }
                    .map { (level: $0.key, resolution: 24 - $0.value.0, count: $0.value.1) }
            }
            // Distinct ladders, each with the tiles that share it: an overview submap
            // has its own, and a detail tile that lost its finest level draws nothing
            // of what the style puts there.
            var shapes: [String: [String]] = [:]
            for (tile, ladder) in ladders {
                let shape = ladder.map { "L\($0.level)→res \($0.resolution)" }
                    .joined(separator: ", ")
                shapes[shape, default: []].append(tile)
            }
            for (shape, tiles) in shapes.sorted(by: { $0.value.count > $1.value.count }) {
                CLILog.line("  zoom ladder ×\(tiles.count): \(shape)")
            }
            if let first = ladders.keys.sorted().first, let ladder = ladders[first] {
                if ladders.count > 1 {
                    let same = ladders.values.allSatisfy { $0.map(\.resolution)
                        == ladder.map(\.resolution) }
                    let finest = ladders.values.compactMap { $0.map(\.resolution).max() }.max() ?? 0
                    let coarsest = ladders.values.compactMap { $0.map(\.resolution).min() }.min() ?? 0
                    CLILog.line("    \(ladders.count) tile(s), "
                                + (same ? "all on the same ladder" : "ladders differ")
                                + " · resolutions \(coarsest)…\(finest)")
                }
            }

            let identity = ImgContainer.typIdentity(in: url)
            if let identity {
                CLILog.line("  TYP: family \(identity.familyID), product \(identity.productID),"
                      + " \(Fmt.bytes(Int64(identity.size)))")
            } else if directory.contains(where: { $0.ext.uppercased() == "TYP" }) {
                CLILog.line("  TYP present but its header could not be read")
            } else {
                CLILog.line("  no TYP inside")
            }
            maps.append(["file": .string(url.lastPathComponent),
                         "path": .string(url.path),
                         "found": true,
                         "isIMG": true,
                         "subFiles": .int(directory.count),
                         "listed": .array(listed.map {
                             ["name": .string($0.fullName), "bytes": .int($0.size),
                              "blocks": .int($0.blocks.count)]
                         }),
                         "typ": identity.map {
                             ["family": .int($0.familyID), "product": .int($0.productID),
                              "bytes": .int($0.size)]
                         } ?? .null])
        }
        CLIOutput.result(["maps": .array(maps)])
        // The per-file verdicts are the answer; the code says whether every file could
        // be read at all, so a script need not parse to notice a wrong path.
        return unreadable == 0 ? 0 : 1
    }

    /// Lifts the TYP out of a map into a plain file kmap can build with, so it can be
    /// inspected or edited by hand.
    static func extractTyp(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["out"])
        let paths = flags.positionals
        guard !paths.isEmpty else {
            return CLIOutput.failure("extract-typ needs a .img path", code: 2)
        }
        let force = flags.has("force")
        let destinationDir = flags.value("out").map { Paths.expand($0) }
            ?? Paths.root.appendingPathComponent("typ", isDirectory: true)
        Paths.ensure(destinationDir)

        // The same confirmation the interface puts up, untranslated, and with no flag
        // that skips it. Under --json the prompt cannot be shown, so the command is
        // refused outright rather than left waiting on an invisible question.
        guard !CLIOutput.isJSON else {
            return CLIOutput.failure(
                "extract-typ asks an interactive copyright confirmation, which --json"
                + " cannot show — run it without --json", code: 2)
        }
        CLILog.line("Important")
        CLILog.line("")
        for path in paths {
            CLILog.line("  file  \(Paths.expand(path).lastPathComponent)")
        }
        CLILog.line("")
        CLILog.line("I confirm that the copyright in the files being imported is mine, or that"
              + " their author has given me permission, or that they are open source and"
              + " copying and editing them is allowed.")
        CLILog.line("")
        CLILog.line("The copy stays on this machine. kmap does not publish it and does not send"
              + " it anywhere; what is done with it afterwards is yours to answer for.")
        CLILog.line("")
        CLILog.write("Type y to confirm: ")
        guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "y" else {
            CLILog.line("nothing was imported")
            return 1
        }

        var failures = 0
        var extracted: [JSONValue] = []
        for path in paths {
            let url = Paths.expand(path)
            guard ImgContainer.isImg(url) else {
                CLILog.error("\(url.lastPathComponent): not a Garmin IMG")
                failures += 1
                continue
            }
            guard let identity = ImgContainer.typIdentity(in: url) else {
                CLILog.error("\(url.lastPathComponent): no TYP inside")
                failures += 1
                continue
            }

            let name = FileTools.slugify(url.deletingPathExtension().lastPathComponent)
            let destination = destinationDir.appendingPathComponent("\(name)-\(identity.familyID).typ")

            if FileTools.exists(destination) && !force {
                CLILog.line("\(Paths.display(destination)) already exists — pass --force to overwrite")
                continue
            }
            guard ImgContainer.extractTYP(from: url, to: destination) else {
                CLILog.error("\(url.lastPathComponent): extraction failed")
                failures += 1
                continue
            }
            CLILog.line("\(Paths.display(destination))  \(Fmt.bytes(FileTools.size(of: destination)))"
                  + "  family \(identity.familyID)")
            extracted.append(["from": .string(url.path),
                              "typ": .string(destination.path),
                              "bytes": .int(Int(FileTools.size(of: destination))),
                              "familyID": .int(identity.familyID),
                              "productID": .int(identity.productID)])
        }

        if failures == 0 {
            CLILog.line("\nEdit the file and build with it — kmap picks up any .typ under "
                  + "\(Paths.display(Paths.root.appendingPathComponent("typ"))) as a style,")
            CLILog.line("and never overwrites one that already exists.")
        }
        CLIOutput.result(["extracted": .array(extracted), "failures": .int(failures)])
        return failures == 0 ? 0 : 1
    }

    /// Writes the TYP source a palette table stands for: the same text a build with that
    /// shipped style compiles.
    static func typgen(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["fid", "out"])
        guard let path = flags.positionals.first else {
            return CLIOutput.failure("typgen needs a palette.txt path", code: 2)
        }
        // `flatMap(Int.init)` is a trap here: function references drop argument labels,
        // so it resolves to the hex-parsing `Int(hex:)` and --fid=6326 becomes 25382.
        let fid = flags.int("fid") ?? 6325
        do {
            let source = Paths.expand(path)
            let palette = try StylePalette.read(
                String(contentsOf: source, encoding: .utf8))
            // Icon and pattern sections live beside the table, ready-made; see
            // points.txt and graphics.txt.
            let points = (try? String(
                contentsOf: source.deletingLastPathComponent()
                    .appendingPathComponent("points.txt"),
                encoding: .utf8)) ?? ""
            let graphics = (try? String(
                contentsOf: source.deletingLastPathComponent()
                    .appendingPathComponent("graphics.txt"),
                encoding: .utf8)) ?? ""
            let text = TypGenerator.text(from: palette, fid: fid, points: points,
                                         graphics: graphics)
            if let out = flags.value("out") {
                let destination = Paths.expand(out)
                try text.write(to: destination, atomically: true, encoding: .utf8)
                CLILog.line("\(Paths.display(destination))  \(palette.polygons.count)"
                      + " polygon(s), \(palette.lines.count) line(s), FID \(fid)")
                CLIOutput.result(["out": .string(destination.path),
                                  "polygons": .int(palette.polygons.count),
                                  "lines": .int(palette.lines.count),
                                  "familyID": .int(fid)])
            } else {
                CLILog.line(text)
                CLIOutput.result(["polygons": .int(palette.polygons.count),
                                  "lines": .int(palette.lines.count),
                                  "familyID": .int(fid),
                                  "text": .string(text)])
            }
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Structural check on a built map before it goes to the device.
    static func verify(_ arguments: [String]) -> Int32 {
        var paths = Flags(arguments).positionals
        if paths.isEmpty {
            // No argument: check everything in the output folder.
            let root = SettingsStore().settings.outputURL
            var found = FileTools.contents(of: root, extension: "img").map(\.path)
            for entry in FileTools.contents(of: root) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                found.append(contentsOf: FileTools.contents(of: entry, extension: "img").map(\.path))
            }
            paths = found
        }
        guard !paths.isEmpty else {
            CLILog.line("no maps to check — pass a .img path, or build one first")
            CLIOutput.result(["maps": .array([])])
            return 0
        }

        var worst: Int32 = 0
        var reported: [JSONValue] = []
        for path in paths {
            let report = MapVerifier.verify(Paths.expand(path))
            CLILog.line("\n\(report.url.lastPathComponent)")
            for finding in report.findings {
                let mark: String
                switch finding.level {
                case .ok: mark = "ok  "
                case .warn: mark = "warn"
                case .fail: mark = "FAIL"
                }
                CLILog.line("  \(mark)  \(finding.label.padding(toLength: 14, withPad: " ", startingAt: 0))"
                      + "  \(finding.detail)")
            }
            reported.append(["file": .string(report.url.lastPathComponent),
                             "path": .string(report.url.path),
                             "ok": .bool(!report.failed),
                             "findings": .array(report.findings.map {
                                 ["level": .string("\($0.level)"),
                                  "label": .string($0.label),
                                  "detail": .string($0.detail)]
                             })])
            if report.failed { worst = max(worst, 1) }
        }
        CLIOutput.result(["maps": .array(reported)])
        return worst
    }

    static func listStyles() -> Int32 {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        let styles = catalog.availableStyles()
        let width = min(46, styles.map(\.id.count).max() ?? 20)
        for style in styles {
            let id = style.id.count >= width
                ? style.id
                : style.id.padding(toLength: width, withPad: " ", startingAt: 0)
            CLILog.line("\(id)  \(style.name)")
            CLILog.line("\(String(repeating: " ", count: width + 2))\(style.summary)")
        }
        CLILog.line("\n\(styles.count) style(s)")
        CLIOutput.result(["styles": .array(styles.map {
            ["id": .string($0.id), "name": .string($0.name),
             "summary": .string($0.summary), "origin": .string($0.origin.name),
             "familyID": .int($0.familyID), "productID": .int($0.productID),
             "typ": .of($0.typURL?.path)]
        })])
        return 0
    }

    /// The profiles `--profile` can name and what each one holds, in ids rather than names
    /// since the ids are what `--style`, `--levels` and `--labels` take. The profile the
    /// interface opens on is marked; a build given no `--profile` takes none of them.
    static func listProfiles() -> Int32 {
        let store = SettingsStore()
        let profiles = store.profiles
        let current = store.currentProfile.id
        let width = min(30, profiles.map(\.name.count).max() ?? 12)
        for profile in profiles {
            let name = profile.name.count >= width
                ? profile.name
                : profile.name.padding(toLength: width, withPad: " ", startingAt: 0)
            CLILog.line(profile.id == current ? "\(name)  (open in the interface)" : profile.name)
            CLILog.line("\(String(repeating: " ", count: width + 2))\(describe(profile.choices))")
        }
        CLILog.line("\n\(profiles.count) profile(s). Build with: kmap build … --profile=<name>")
        CLILog.line("Optional: a build given no --profile switches on only what its flags say.")
        CLIOutput.result(["profiles": .array(profiles.map {
            ["id": .string($0.id), "name": .string($0.name),
             "current": .bool($0.id == current),
             "summary": .string(describe($0.choices)),
             "choices": choicesAsData($0.choices)]
        })])
        return 0
    }

    /// The same choices as data, for a reader that is not a person. Every field a
    /// profile holds, under the names the flags use.
    static func choicesAsData(_ choices: BuildChoices) -> JSONValue {
        ["style": .string(choices.styleID),
         "contours": .bool(choices.contours),
         "interval": .int(choices.contourInterval),
         "dem": .bool(choices.demLayer),
         "summits": .bool(choices.fixSummits),
         "sources": .string(choices.demSources),
         "levels": .string(choices.levelsID),
         "labels": .string(choices.labelLanguageID),
         "codePage": .int(choices.codePage),
         "split": .string(choices.splitMode),
         "parts": .int(choices.parts),
         "hide": .array(choices.hiddenFeatures.map(JSONValue.string))]
    }

    /// One profile on one line.
    static func describe(_ choices: BuildChoices) -> String {
        var parts = ["style \(choices.styleID)"]
        parts.append(choices.contours ? "contours \(choices.contourInterval) m"
                                      : "no contours")
        parts.append(choices.demLayer ? "DEM" : "no DEM")
        if choices.contours || choices.demLayer { parts.append(choices.demSources) }
        parts.append("levels \(choices.levelsID)")
        parts.append("labels \(choices.labelLanguageID)")
        parts.append(choices.codePage == 0 ? "code page by region"
                                           : "code page \(choices.codePage)")
        parts.append("split \(choices.splitMode)"
                     + (choices.splitMode == "custom" ? " \(choices.parts)" : ""))
        if !choices.hiddenFeatures.isEmpty {
            parts.append("hides \(choices.hiddenFeatures.joined(separator: ","))")
        }
        return parts.joined(separator: " · ")
    }
}
