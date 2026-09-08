#!/bin/bash
# The Windows installer, from a bash prompt (Git Bash or MSYS) on Windows. The work is in
# windows-package.ps1; this only finds a PowerShell and hands over.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/windows-package.ps1"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) ;;
    *)
        echo "this builds a Windows installer, and needs Windows to build it on" >&2
        echo "on the Windows machine, from Git Bash:  Scripts/build-windows.sh" >&2
        exit 1
        ;;
esac

for candidate in pwsh powershell powershell.exe; do
    if command -v "$candidate" >/dev/null 2>&1; then
        exec "$candidate" -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT" "$@"
    fi
done

echo "no powershell found on the PATH" >&2
exit 1
