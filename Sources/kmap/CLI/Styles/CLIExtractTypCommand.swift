import Foundation

/// `kmap extract-typ`: the TYP lifted out of a map into a plain file kmap can build with,
/// so it can be inspected or edited by hand.
extension CLI {
    static func extractTyp(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["out"])
        let paths = flags.positionals
        guard !paths.isEmpty else {
            return CLIOutput.refuse("extract-typ needs a .img path")
        }
        // The same confirmation the interface puts up, with no flag that skips it. Under
        // --json the prompt cannot be shown, so the command is refused outright rather
        // than left waiting on an invisible question.
        guard !CLIOutput.isJSON else {
            return CLIOutput.refuse(
                "extract-typ asks an interactive copyright confirmation, which --json"
                    + " cannot show — run it without --json"
            )
        }
        guard confirmedCopyright(of: paths) else {
            CLILog.line("nothing was imported")
            return 1
        }

        let force = flags.has("force")
        let destinationDir =
            flags.value("out").map { Paths.expand($0) }
            ?? Paths.root.appendingPathComponent("typ", isDirectory: true)
        Paths.ensure(destinationDir)

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
            CLILog.line(
                "\(Paths.display(destination))  \(Fmt.bytes(FileTools.size(of: destination)))"
                    + "  family \(identity.familyID)"
            )
            extracted.append([
                "from": .string(url.path),
                "typ": .string(destination.path),
                "bytes": .int(Int(FileTools.size(of: destination))),
                "familyID": .int(identity.familyID),
                "productID": .int(identity.productID)
            ])
        }

        if failures == 0 {
            CLILog.line(
                "\nEdit the file and build with it — kmap picks up any .typ under "
                    + "\(Paths.display(Paths.root.appendingPathComponent("typ"))) as a style,"
            )
            CLILog.line("and never overwrites one that already exists.")
        }
        CLIOutput.result(["extracted": .array(extracted), "failures": .int(failures)])
        return failures == 0 ? 0 : 1
    }

    /// Asks, on the terminal, and answers whether the user typed y.
    private static func confirmedCopyright(of paths: [String]) -> Bool {
        CLILog.line("Important")
        CLILog.line("")
        for path in paths {
            CLILog.line("  file  \(Paths.expand(path).lastPathComponent)")
        }
        CLILog.line("")
        CLILog.line(
            "I confirm that the copyright in the files being imported is mine, or that"
                + " their author has given me permission, or that they are open source and"
                + " copying and editing them is allowed."
        )
        CLILog.line("")
        CLILog.line(
            "The copy stays on this machine. kmap does not publish it and does not send"
                + " it anywhere; what is done with it afterwards is yours to answer for."
        )
        CLILog.line("")
        CLILog.write("Type y to confirm: ")
        return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "y"
    }
}
