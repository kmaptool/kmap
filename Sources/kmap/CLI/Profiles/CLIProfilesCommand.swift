import Foundation

/// `kmap profiles`: the saved sets of build choices, managed from the shell with the
/// vocabulary the build command speaks. Bare, it lists what there is.
extension CLI {
    static func profiles(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first, !verb.hasPrefix("--") else {
            return listProfiles()
        }
        let rest = Array(arguments.dropFirst())
        let store = SettingsStore()
        switch verb {
        case "show": return showProfile(rest, store: store)
        case "new": return newProfile(rest, store: store)
        case "set": return setProfile(rest, store: store)
        case "copy": return copyProfile(rest, store: store)
        case "rename": return renameProfile(rest, store: store)
        case "delete": return deleteProfile(rest, store: store)
        case "use": return useProfile(rest, store: store)
        default:
            return CLIOutput.refuse(
                "unknown profiles verb \"\(verb)\" — one of: show, new, set, copy,"
                    + " rename, delete, use; bare `kmap profiles` lists them"
            )
        }
    }

    // MARK: The verbs

    private static func showProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard let profile = named(arguments.first, in: store) else {
            return missingProfile(arguments.first)
        }
        for (label, value) in profileRows(profile, store: store) {
            CLILog.line("\(label.padding(toLength: profileLabelColumn, withPad: " ", startingAt: 0))\(value)")
        }
        CLIOutput.result(["profile": profileAsData(profile, store: store)])
        return 0
    }

    private static func newProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            return CLIOutput.refuse("usage: kmap profiles new <name> [build options]")
        }
        guard named(name, in: store) == nil else {
            return CLIOutput.refuse(
                "a profile called \"\(name)\" already exists — `kmap profiles set` changes"
                    + " it, `kmap profiles copy` starts another from it"
            )
        }
        var choices = BuildChoices()
        let refused = apply(Flags(Array(arguments.dropFirst())), to: &choices, store: store)
        guard refused.isEmpty else { return CLIOutput.refuse(refused) }
        let made = store.addProfile(named: name, choices: choices)
        CLILog.line("\(made.name): \(describe(made.choices))")
        CLIOutput.result(["profile": profileAsData(made, store: store)])
        return 0
    }

    private static func setProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard var profile = named(arguments.first, in: store) else {
            return missingProfile(arguments.first)
        }
        let flags = Flags(Array(arguments.dropFirst()))
        guard !flags.names.isEmpty else {
            return CLIOutput.refuse(
                "nothing to change — give `kmap profiles set` the same build options"
                    + " `kmap build` takes, e.g. --interval=25 --no-dem"
            )
        }
        let refused = apply(flags, to: &profile.choices, store: store)
        guard refused.isEmpty else { return CLIOutput.refuse(refused) }
        store.saveProfile(profile)
        CLILog.line("\(profile.name): \(describe(profile.choices))")
        CLIOutput.result(["profile": profileAsData(profile, store: store)])
        return 0
    }

    private static func copyProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard arguments.count >= 2 else {
            return CLIOutput.refuse("usage: kmap profiles copy <name> <new-name>")
        }
        guard let source = named(arguments[0], in: store) else {
            return missingProfile(arguments[0])
        }
        guard named(arguments[1], in: store) == nil else {
            return CLIOutput.refuse("a profile called \"\(arguments[1])\" already exists")
        }
        let made = store.addProfile(named: arguments[1], choices: source.choices)
        CLILog.line("\(source.name) → \(made.name)")
        CLIOutput.result(["profile": profileAsData(made, store: store)])
        return 0
    }

    private static func renameProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard arguments.count >= 2 else {
            return CLIOutput.refuse("usage: kmap profiles rename <name> <new-name>")
        }
        guard let profile = named(arguments[0], in: store) else {
            return missingProfile(arguments[0])
        }
        // A clash with itself is no clash: renaming Watch to watch is a case change.
        if let taken = named(arguments[1], in: store), taken.id != profile.id {
            return CLIOutput.refuse("a profile called \"\(arguments[1])\" already exists")
        }
        store.renameProfile(profile.id, to: arguments[1])
        let renamed = store.profile(profile.id) ?? profile
        CLILog.line("\(profile.name) → \(renamed.name)")
        CLIOutput.result(["profile": profileAsData(renamed, store: store)])
        return 0
    }

    private static func deleteProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard let profile = named(arguments.first, in: store) else {
            return missingProfile(arguments.first)
        }
        guard store.deleteProfile(profile.id) else {
            return CLIOutput.refuse(
                "\"\(profile.name)\" is the last profile — the build form needs one, so"
                    + " make another before deleting it"
            )
        }
        CLILog.line("deleted \(profile.name)")
        CLIOutput.result(["deleted": .string(profile.name)])
        return 0
    }

    private static func useProfile(_ arguments: [String], store: SettingsStore) -> Int32 {
        guard let profile = named(arguments.first, in: store) else {
            return missingProfile(arguments.first)
        }
        store.useProfile(profile.id)
        CLILog.line("\(profile.name) is what the interface opens on now")
        CLIOutput.result(["profile": profileAsData(profile, store: store)])
        return 0
    }

    // MARK: Naming one

    /// The profile a verb names, matched the way `--profile` matches: by name, without
    /// regard to case.
    private static func named(_ name: String?, in store: SettingsStore) -> BuildProfile? {
        guard let name, !name.hasPrefix("--") else { return nil }
        return store.profiles.first {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    private static func missingProfile(_ name: String?) -> Int32 {
        guard let name, !name.hasPrefix("--") else {
            return CLIOutput.refuse("which profile? — `kmap profiles` lists them")
        }
        return CLIOutput.refuse("no profile called \"\(name)\" — see `kmap profiles`")
    }
}
