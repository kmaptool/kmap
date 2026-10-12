import Foundation

extension StyleCatalog {
    enum StyleError: Error, LocalizedError {
        case noMkgmap
        case extractionFailed(String)
        case usersOwnFolder(String)
        case sheetUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .noMkgmap: return t("mkgmap.jar is needed to unpack the base style")
            case .extractionFailed(let m): return t("could not unpack the base style: %@", m)
            case .usersOwnFolder(let path):
                return t("%@ is a folder of your own, which kmap does not replace: rename it", path)
            case .sheetUnreadable(let path):
                return t("the reassignment sheet %@ cannot be read", path)
            }
        }
    }
}
