import Foundation

/// The command line's argument parser. A flag is `--key=value`, `--key value` for the keys
/// a command declares as taking a value, or a bare `--flag`; everything else is positional.
/// No abbreviations and no combining, so an unknown flag is left unread rather than matched
/// to a near one.
extension CLI {
    struct Flags {
        private var values: [String: [String]] = [:]
        private var present: Set<String> = []
        /// The arguments that were not flags and not a flag's value, in order.
        let positionals: [String]

        /// - Parameter valued: the keys that take the NEXT argument as their value when no
        ///   `=` is written. Declared per command rather than guessed: without it,
        ///   `--quiet map.img` would take the path as the value of `--quiet`.
        init(_ arguments: [String], valued: Set<String> = []) {
            var positionals: [String] = []
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                index += 1
                guard argument.hasPrefix("--"), argument.count > 2 else {
                    positionals.append(argument)
                    continue
                }
                let body = String(argument.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    let key = String(body[body.startIndex..<eq])
                    values[key, default: []].append(String(body[body.index(after: eq)...]))
                    present.insert(key)
                } else if valued.contains(body), index < arguments.count {
                    values[body, default: []].append(arguments[index])
                    present.insert(body)
                    index += 1
                } else {
                    present.insert(body)
                }
            }
            self.positionals = positionals
        }

        /// Whether the flag was written at all, with a value or without.
        func has(_ name: String) -> Bool { present.contains(name) }

        /// Every flag that was written, for a command that wants to refuse the ones it
        /// does not know rather than skip a typo silently.
        var names: Set<String> { present }

        /// The flag's value; the last one where it was written more than once.
        func value(_ name: String) -> String? { values[name]?.last }

        /// Every value the flag was given, for the ones that may repeat (`--extract`).
        func values(_ name: String) -> [String] { values[name] ?? [] }

        func int(_ name: String) -> Int? { value(name).flatMap { Int($0) } }
        func double(_ name: String) -> Double? { value(name).flatMap { Double($0) } }
    }
}
