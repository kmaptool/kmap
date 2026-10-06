import Foundation

/// Which language the map's labels come out in. Becomes `--name-tag-list`; unrelated to
/// the language the interface speaks. Names and notes are held as catalogue keys rather
/// than text because these are `static let`s: a string built once would keep the language
/// it was first built in.
struct LabelLanguage: Equatable {
    let id: String
    let nameKey: String
    /// Passed to mkgmap's `--name-tag-list`; empty means the flag is not passed.
    let tagList: String
    let noteKey: String

    var name: String { t(nameKey) }
    var note: String { t(noteKey) }

    static let local = LabelLanguage(
        id: "local",
        nameKey: "Local",
        tagList: "",
        noteKey: "whatever the local mappers wrote — Russian in Russia, German in Germany"
    )

    /// The local name before `int_name`, as a 1251 build does by default: in Russia a
    /// place without `name:ru` is named in Cyrillic, and `int_name` is its Latin spelling.
    static let russian = LabelLanguage(
        id: "ru",
        nameKey: "Russian",
        tagList: "name:ru,name,int_name",
        noteKey: "prefer the Russian name where OSM has one"
    )

    static let english = LabelLanguage(
        id: "en",
        nameKey: "English",
        tagList: "name:en,int_name,name",
        noteKey: "prefer the English name where OSM has one"
    )

    static let all = [local, russian, english]
}
