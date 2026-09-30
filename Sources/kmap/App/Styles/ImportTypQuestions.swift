import Foundation

/// The questions before an import, the import itself, and the offer after it.
extension ImportTypScreen {
    /// A file already held byte for byte is named instead of copied again.
    func ask(about url: URL, candidate: TypCandidate?) {
        var detail: [(label: String, value: String)] = [
            (t("file"), url.lastPathComponent),
            (t("from"), Paths.display(url.deletingLastPathComponent()))
        ]
        if let candidate {
            detail.append((t("size"), Fmt.bytes(candidate.size)))
            detail.append((t("family"), "\(candidate.familyID) · \(candidate.productID)"))
        }
        if let name = held.exact[TypLibrary.fingerprint(ofTypAt: url)] {
            notice.say(t("already in the library as %@ · in styles: c copies it, o brings back the original", name))
            return
        }
        let pending: Pending = (url, detail)
        guard ImgContainer.isImg(url) else {
            warning = Question(
                dialog: Dialog(
                    title: t("Only the drawing"),
                    body: [
                        t(
                            "A TYP file holds the drawing: colours, patterns, icons. Which"
                                + " code stands for a forest or a trunk road is not in it — that is"
                                + " read out of the map itself."
                        ),
                        t(
                            "So recovering the style is not available for a TYP on its own."
                                + " If you have the .img this file came from, import that instead:"
                                + " kmap takes the TYP out of it and can work the codes out too."
                        )
                    ],
                    detail: detail,
                    confirm: t("import anyway"),
                    cancel: t("cancel"),
                    tone: .plain
                ),
                subject: pending
            )
            return
        }
        askAboutRights(pending)
    }

    func askAboutRights(_ pending: Pending) {
        asking = Question(
            dialog: Dialog(
                title: t("Important"),
                body: [
                    t(
                        "I confirm that the copyright in the files being imported is mine, or"
                            + " that their author has given me permission, or that they are open"
                            + " source and copying and editing them is allowed."
                    ),
                    t(
                        "The copy stays on this machine. kmap does not publish it and does not"
                            + " send it anywhere; what is done with it afterwards is yours to answer"
                            + " for."
                    )
                ],
                detail: pending.detail,
                confirm: t("I confirm"),
                cancel: t("cancel")
            ),
            subject: pending
        )
    }

    /// Copies the TYP into the library, lifted out of a `.img` and decompiled where
    /// there is one to decompile.
    func take(_ url: URL, ctx: AppContext) {
        do {
            let result = try TypLibrary.take(at: url)
            TypLibrary.recordImport(
                from: url,
                to: result.url,
                fingerprint: result.fingerprint,
                note: "rights confirmed by the user"
            )
            notice.say(describe(result, from: url))
            path = ""
            refreshHeld()
            ctx.styles.rescanStyles()
            onImported()
            // The map holds the other half of the style: which code stands for what.
            if ImgContainer.isImg(url) { offerRecovery(img: url, typ: result.url) }
        } catch {
            notice.say(error.localizedDescription, error: true)
        }
    }

    private func offerRecovery(img: URL, typ: URL) {
        offering = Question(
            dialog: Dialog(
                title: t("Recover the style?"),
                body: [
                    t(
                        "A TYP records how type codes are drawn. The map records the"
                            + " other half: which code stands for a forest or a trunk road."
                            + " kmap can read that out of the map — builds with this style"
                            + " then look the same as the original."
                    ),
                    t("The whole map is read, which takes a few minutes.")
                ],
                detail: [(t("map"), img.lastPathComponent)],
                confirm: t("recover"),
                cancel: t("not now"),
                tone: .plain
            ),
            subject: (img, typ)
        )
    }

    /// Where the copy landed and how completely the source was decoded.
    private func describe(_ result: TypLibrary.Imported, from url: URL) -> String {
        var parts: [String] = []
        if ImgContainer.isImg(url) {
            parts.append(t("lifted out of %@", url.lastPathComponent))
        }
        if result.decompiled {
            parts.append(tn("decompiled %d element(s)", result.elements))
            if result.refused > 0 {
                parts.append(tn("%d not fully decoded — marked in the file", result.refused))
            }
        }
        parts.append("→ \(Paths.display(result.url))")
        return parts.joined(separator: " · ")
    }
}
