import Foundation
@testable import kmap

/// The shell this machine has, and the scripts the process tests ask it for.
///
/// Every platform can run all of them and none spells them the same way: `/bin/sh -c` on
/// the Unixes, `cmd /c` and a different language on Windows, which has no `sh` at all.
enum TestShell {

    /// The shell itself.
    static var path: String {
        #if os(Windows)
        return (ProcessInfo.processInfo.environment.variable("ComSpec")
                ?? #"C:\Windows\System32\cmd.exe"#)
        #else
        return "/bin/sh"
        #endif
    }

    /// The arguments that run `script`.
    static func arguments(_ script: Script) -> [String] {
        #if os(Windows)
        return ["/c", script.cmd]
        #else
        return ["-c", script.sh]
        #endif
    }

    enum Script {
        /// Two lines, in order.
        case twoLines
        /// One line with no newline after it — how mkgmap's last word often arrives.
        case withoutTrailingNewline
        /// One line to each stream.
        case toBothStreams
        /// A reason on standard error, and a non-zero exit.
        case failWithReason
        /// Nothing at all, and exit 7.
        case exitSeven
        /// Read a line from standard input and say what came.
        case echoWhatWasTyped
        /// Half a minute of nothing.
        case sleep
        /// Where it is running.
        case printWorkingDirectory
        /// `KMAP_TEST_VALUE` or the word "unset", then whether PATH survived.
        case reportEnvironment
        /// Two lines ended the way a Windows program ends them, from any shell.
        case twoLinesWithCarriageReturns

        var sh: String {
            switch self {
            case .twoLines: return "echo one; echo two"
            case .withoutTrailingNewline: return "printf 'no newline here'"
            case .toBothStreams: return "echo out; echo err 1>&2"
            case .failWithReason: return "echo the reason 1>&2; exit 3"
            case .exitSeven: return "exit 7"
            case .echoWhatWasTyped: return "read line; echo \"got:$line\""
            case .sleep: return "sleep 30"
            case .printWorkingDirectory: return "pwd"
            case .reportEnvironment:
                return "echo ${KMAP_TEST_VALUE:-unset}; echo ${PATH:+path-is-set}"
            case .twoLinesWithCarriageReturns:
                return "printf 'one\\r\\ntwo\\r\\n'"
            }
        }

        var cmd: String {
            switch self {
            case .twoLines: return "echo one& echo two"
            // `<nul set /p=` is how cmd prints without a newline; it has no printf.
            // `set /p` exits 1 at end of input, so the exit code is forced back to 0.
            case .withoutTrailingNewline: return "<nul set /p=no newline here& exit /b 0"
            // Parenthesised: `echo err 1>&2` would echo the space before the redirection.
            case .toBothStreams: return "echo out&(echo err)1>&2"
            case .failWithReason: return "(echo the reason)1>&2& exit /b 3"
            case .exitSeven: return "exit /b 7"
            // cmd expands `%line%` before the line runs and delayed expansion is off
            // under `/c`, so the branch turns on whether `set /p` succeeded.
            case .echoWhatWasTyped: return "set /p line=&& echo got:something || echo got:"
            // Not `timeout`: it refuses when stdin is redirected, and every child gets NUL.
            case .sleep: return "ping -n 31 127.0.0.1 >nul"
            case .printWorkingDirectory: return "cd"
            case .reportEnvironment:
                // Each `if` in brackets of its own: an `&` after an `else` block is read
                // as part of that block.
                return "(if defined KMAP_TEST_VALUE (echo %KMAP_TEST_VALUE%) else (echo unset))"
                    + "&(if defined PATH echo path-is-set)"
            // cmd already ends every line this way.
            case .twoLinesWithCarriageReturns: return "echo one& echo two"
            }
        }
    }

    /// A command that prints exactly `text` and stops. Not the shell: it stands in for a
    /// tool being asked its version.
    static func echo(_ text: String) -> (executable: String, arguments: [String]) {
        #if os(Windows)
        return (path, ["/c", "echo " + text])
        #else
        return ("/bin/echo", [text])
        #endif
    }

    /// A path nothing could be at, spelled for this machine.
    static var nowhere: String {
        #if os(Windows)
        return #"C:\nowhere\at\all\mkgmap.exe"#
        #else
        return "/nowhere/at/all/mkgmap"
        #endif
    }
}
