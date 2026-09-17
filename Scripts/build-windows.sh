#!/bin/bash
# The Windows installer, built on Windows from a bash prompt (Git Bash or MSYS). The work
# is in windows-package.ps1; this finds a PowerShell and hands over.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/windows-package.ps1"

# ---------------------------------------------------------------- the machine

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) ;;
    *)
        echo "this builds a Windows installer, and needs Windows to build it on" >&2
        exit 1
        ;;
esac
POWERSHELL=""
for candidate in pwsh powershell powershell.exe; do
    if command -v "$candidate" >/dev/null 2>&1; then POWERSHELL="$candidate"; break; fi
done
if [ -z "$POWERSHELL" ]; then
    echo "missing:" >&2
    echo "  powershell" >&2
    exit 1
fi

# ---------------------------------------------------------------- the build

exec "$POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT" "$@"
