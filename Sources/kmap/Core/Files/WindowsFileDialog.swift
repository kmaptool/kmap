#if os(Windows)
import Foundation
import WinSDK

/// Windows's own dialogs, shown from this process.
///
/// The dialog used to be a `powershell.exe` child, and a child shares this console: it
/// handed it back with another code page, another font and another size, which broke
/// every glyph the interface draws. Nothing is started here, so there is nothing to hand
/// the console to.
enum WindowsFileDialog {

    /// Shows the open dialog. Returns the chosen path, or nil when it was cancelled.
    static func file(extensions: [String], startingAt start: String?, title: String) -> String? {
        // The shell's own places and thumbnails come with OLE started; the dialog works
        // without it, so a thread already in another apartment is no reason to stop.
        let ole = OleInitialize(nil)
        defer { if ole >= 0 { OleUninitialize() } }

        var chosen = [WCHAR](repeating: 0, count: 4096)
        let filter = filterList(extensions)
        let name = wide(title)
        let directory = start.map(wide)

        return chosen.withUnsafeMutableBufferPointer { file -> String? in
            filter.withUnsafeBufferPointer { patterns -> String? in
                name.withUnsafeBufferPointer { caption -> String? in
                    var options = OPENFILENAMEW()
                    options.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                    options.hwndOwner = owner()
                    options.lpstrFile = file.baseAddress
                    options.nMaxFile = DWORD(file.count)
                    options.lpstrFilter = patterns.baseAddress
                    options.nFilterIndex = 1
                    options.lpstrTitle = caption.baseAddress
                    // NOCHANGEDIR: the dialog must not move this process's own directory.
                    options.Flags = DWORD(OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST
                                          | OFN_NOCHANGEDIR | OFN_HIDEREADONLY)

                    // The starting folder's buffer has to outlive the call, so the dialog
                    // is shown inside its scope.
                    if let directory {
                        return directory.withUnsafeBufferPointer { start -> String? in
                            options.lpstrInitialDir = start.baseAddress
                            guard GetOpenFileNameW(&options) else { return nil }
                            return answer(in: file)
                        }
                    }
                    guard GetOpenFileNameW(&options) else { return nil }
                    return answer(in: file)
                }
            }
        }
    }

    /// Shows the folder browser. Returns the chosen folder, or nil when it was cancelled.
    static func directory(startingAt start: String?, title: String) -> String? {
        // BIF_USENEWUI asks for the resizable browser, and that one wants OLE started.
        let ole = OleInitialize(nil)
        defer { if ole >= 0 { OleUninitialize() } }

        startSelection = start.map(wide) ?? []
        defer { startSelection = [] }

        let name = wide(title)
        var display = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        return name.withUnsafeBufferPointer { caption -> String? in
            display.withUnsafeMutableBufferPointer { shown -> String? in
                var info = BROWSEINFOW()
                info.hwndOwner = owner()
                info.pszDisplayName = shown.baseAddress
                info.lpszTitle = caption.baseAddress
                info.ulFlags = UINT(BIF_RETURNONLYFSDIRS
                                    | (ole >= 0 ? BIF_USENEWUI : 0))
                if !startSelection.isEmpty { info.lpfn = openAtTheStartingFolder }
                guard let list = SHBrowseForFolderW(&info) else { return nil }
                defer { CoTaskMemFree(list) }

                var path = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
                guard SHGetPathFromIDListW(list, &path) else { return nil }
                return answer(in: path)
            }
        }
    }

    /// The window a dialog belongs in front of: the console's own, and nothing when that
    /// window is not on screen — a tabbed terminal keeps a hidden one, and a dialog owned
    /// by a hidden window opens behind everything.
    private static func owner() -> HWND? {
        guard let window = GetConsoleWindow(), IsWindowVisible(window) else { return nil }
        return window
    }

    /// The path a dialog wrote into the buffer, or nil where it wrote nothing.
    private static func answer<Buffer: Collection>(in buffer: Buffer) -> String?
        where Buffer.Element == WCHAR {
        guard let start = buffer.first, start != 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
    }

    // MARK: The folder the browser opens at

    /// The folder to select when the browser opens. The browser is told through a callback
    /// that cannot capture anything, and only one dialog is ever up, on this thread.
    nonisolated(unsafe) private static var startSelection: [WCHAR] = []

    private static let openAtTheStartingFolder: BFFCALLBACK = { window, message, _, _ in
        if message == UINT(BFFM_INITIALIZED), !startSelection.isEmpty {
            startSelection.withUnsafeBufferPointer { start in
                guard let folder = start.baseAddress else { return }
                // The message takes the string as a number, which is what LPARAM is.
                _ = SendMessageW(window, UINT(BFFM_SETSELECTIONW), WPARAM(1),
                                 LPARAM(Int(bitPattern: UnsafeRawPointer(folder))))
            }
        }
        return 0
    }

    // MARK: Text the dialogs read

    /// The filter the open dialog takes: pairs of label and patterns, each ending in a
    /// null, and an empty string to end the list.
    private static func filterList(_ extensions: [String]) -> [WCHAR] {
        var pairs = [(String, String)]()
        if !extensions.isEmpty {
            pairs.append((t("supported files"),
                          extensions.map { "*.\($0)" }.joined(separator: ";")))
        }
        pairs.append((t("all files"), "*.*"))

        var units = [WCHAR]()
        for (label, patterns) in pairs {
            units += wide(label)
            units += wide(patterns)
        }
        units.append(0)
        return units
    }

    /// `text` as UTF-16 with the null the API reads to.
    private static func wide(_ text: String) -> [WCHAR] { Array(text.utf16) + [0] }
}
#endif
