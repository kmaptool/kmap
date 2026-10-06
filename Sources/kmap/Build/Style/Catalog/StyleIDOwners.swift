import Foundation

/// Which style holds each id where 2 names make 1 id, so a file added or removed later
/// does not move a saved id to another style.
enum StyleIDOwners {
    static var file: URL { Paths.root.appendingPathComponent("style-ids.json") }

    /// What a style is told apart by: its TYP file, its folder, or its id.
    static func key(of style: MapStyle) -> String {
        if case .importedTYP(let url) = style.origin { return url.lastPathComponent }
        if case .customDirectory(let url) = style.origin { return url.lastPathComponent }
        return style.id
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
            let owners = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return owners
    }

    /// Records who holds each id now, numbered ones too; written only when that changed.
    static func remember(_ styles: [MapStyle], was: [String: String]) {
        var owners: [String: String] = [:]
        for style in styles where style.origin != .builtin { owners[style.id] = key(of: style) }
        guard owners != was, let data = try? JSONEncoder().encode(owners) else { return }
        try? FileTools.write(data, to: file)
    }
}
