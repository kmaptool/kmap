<#
.SYNOPSIS
  Build kmap for Windows and lay out everything it needs to run on a machine without Swift.

.DESCRIPTION
  Swift for Windows has no static standard library, so the runtime DLLs travel beside the
  binary. This script builds kmap, copies only the DLLs the binary transitively imports,
  and, with Inno Setup installed, compiles the installer. Without Inno Setup the staging
  folder runs as it stands.

  Both architectures can be built from either kind of machine. `VsDevCmd -arch=<target>`
  cannot be used for that: SwiftPM links Package.swift for the toolchain's own
  architecture and fails before reaching kmap. So the environment stays on the host's
  architecture and the target's libraries are handed to the product link with /LIBPATH:,
  which lld-link reads before the LIB variable.

.PARAMETER Configuration
  release (the default) or debug.

.PARAMETER Architectures
  Which to build. Both by default; name one to build only that.

.PARAMETER SkipBuild
  Package what is already staged, without building anything.
#>
[CmdletBinding()]
param(
    [ValidateSet("release", "debug")] [string] $Configuration = "release",
    [ValidateSet("arm64", "x64")] [string[]] $Architectures = @("arm64", "x64"),
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = Split-Path -Parent $PSScriptRoot
$installerOut = Join-Path $root "build\windows"
# One folder per architecture; the installer carries whichever ones are there.
$payloads = Join-Path $installerOut "payload"
$hostArchitecture = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }

# ---------------------------------------------------------------- the environments

$script:visualStudio = $null

function Find-VisualStudio {
    if ($script:visualStudio) { return $script:visualStudio }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "Visual Studio Build Tools are not installed - Swift on Windows links with MSVC's linker. winget install Microsoft.VisualStudio.2022.BuildTools"
    }
    $script:visualStudio = & $vswhere -products * -latest -property installationPath
    return $script:visualStudio
}

# The host's own MSVC environment, never the target's (see the header). The target's
# libraries are handed to the product link in Get-TargetLinkFlags.
function Import-BuildEnvironment {
    $vs = Find-VisualStudio
    $devcmd = Join-Path $vs "Common7\Tools\VsDevCmd.bat"
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    $line = "`"$devcmd`" -arch=$arch -host_arch=$arch >nul && set"
    cmd /c $line | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
    }
}

# Link flags for a target that is not the host: MSVC's, the Windows SDK's and the Swift
# SDK's libraries for that architecture.
function Get-TargetLinkFlags {
    param([string] $Architecture)

    $vs = Find-VisualStudio
    $msvc = Get-ChildItem (Join-Path $vs "VC\Tools\MSVC") -Directory |
            Sort-Object Name -Descending | Select-Object -First 1
    $kit = "${env:ProgramFiles(x86)}\Windows Kits\10"
    $kitVersion = Get-ChildItem (Join-Path $kit "Lib") -Directory |
                  Sort-Object Name -Descending | Select-Object -First 1
    # MSVC and the Windows SDK call it x64; Swift calls it x86_64.
    $swiftArch = if ($Architecture -eq "x64") { "x86_64" } else { "aarch64" }
    # One per line, each in brackets: a comma inside a Join-Path argument list makes an array.
    $libraries = @(
        (Join-Path $msvc.FullName "lib\$Architecture")
        (Join-Path $kitVersion.FullName "ucrt\$Architecture")
        (Join-Path $kitVersion.FullName "um\$Architecture")
    )
    foreach ($path in $libraries) {
        if (-not (Test-Path $path)) {
            throw "no $Architecture libraries at $path - install that architecture's build tools and Windows SDK"
        }
    }
    $swiftSdk = $env:SDKROOT
    $swift = Join-Path $swiftSdk "usr\lib\swift\windows\$swiftArch"
    if (-not (Test-Path $swift)) { throw "the Swift SDK has no $swiftArch libraries at $swift" }

    $flags = @("--triple", "$swiftArch-unknown-windows-msvc",
               "-Xswiftc", "-L", "-Xswiftc", $swift)
    foreach ($path in $libraries) { $flags += @("-Xlinker", "/LIBPATH:$path") }
    return $flags
}

function Find-SwiftRuntime {
    $swift = (Get-Command swift -ErrorAction SilentlyContinue).Source
    if (-not $swift) {
        # A shell opened before the toolchain was installed still has the old PATH, so
        # look at the PATH recorded in the registry as well.
        $recorded = @("Machine", "User") | ForEach-Object {
            [Environment]::GetEnvironmentVariable("Path", $_)
        }
        foreach ($directory in ($recorded -join ";").Split(";")) {
            if (-not $directory) { continue }
            $candidate = Join-Path $directory "swift.exe"
            if (Test-Path $candidate) { $swift = $candidate; break }
        }
        if ($swift) { $env:Path = "$(Split-Path -Parent $swift);$env:Path" }
    }
    if (-not $swift) {
        throw "swift is not on the PATH - winget install Swift.Toolchain"
    }
    # ...\Toolchains\<version>+Asserts\usr\bin\swift.exe -> ...\Runtimes\<version>\usr\bin
    $programs = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $swift))))
    $script:swiftPrograms = $programs

    # SDKROOT is recorded in the user's environment by the installer; take it from the
    # registry if this shell predates it, else work it out from the toolchain's location.
    if (-not $env:SDKROOT) {
        $env:SDKROOT = @("User", "Machine") |
            ForEach-Object { [Environment]::GetEnvironmentVariable("SDKROOT", $_) } |
            Where-Object { $_ } | Select-Object -First 1
    }
    if (-not $env:SDKROOT) {
        $platform = Get-ChildItem (Join-Path $programs "Platforms") -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | Select-Object -First 1
        if ($platform) {
            $env:SDKROOT = Join-Path $platform.FullName "Windows.platform\Developer\SDKs\Windows.sdk"
        }
    }
    if (-not $env:SDKROOT) { throw "no Windows.sdk found under $programs" }

    $runtimes = Join-Path $programs "Runtimes"
    $newest = Get-ChildItem $runtimes -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { throw "no Swift runtime found under $runtimes" }
    $bin = Join-Path $newest.FullName "usr\bin"
    # swift.exe is itself a Swift program and cannot start without these DLLs on the PATH.
    if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }
    return $bin
}

# ---------------------------------------------------------- the other architecture's runtime

# The toolchain installs runtime DLLs only for the host, but ships redistributable merge
# modules for every architecture. A merge module is an MSI database with a cab inside:
# extract the cab with the Windows SDK's MsiDb, expand it, and restore the real file names
# from the File table.
function Export-RuntimeFromMergeModule {
    param([string] $Architecture, [string] $SwiftPrograms, [string] $Into)

    if (Test-Path (Join-Path $Into "swiftCore.dll")) { return }

    $moduleArch = if ($Architecture -eq "x64") { "amd64" } else { "arm64" }
    $redistributables = Join-Path $SwiftPrograms "Redistributables"
    $version = Get-ChildItem $redistributables -Directory -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 1
    if (-not $version) { throw "no redistributables under $redistributables" }
    # `rtl.<arch>.msm`, not `rtl.shared.<arch>.msm`. The toolchain ships several variants
    # side by side and they are not the same build: the shared one carries a swiftCore.dll
    # that does not export everything the SDK's import library promises. Linking against
    # the SDK and shipping that DLL gives a binary which installs and then dies at start
    # with "the procedure entry point $sSE6encode2toys7Encoder_p_tKFTq could not be
    # located" -- exactly the symbols below are missing from it. `rtl.<arch>.msm` matches
    # the SDK, and for the host architecture matches the installed runtime byte for byte.
    $module = Join-Path $version.FullName "rtl.$moduleArch.msm"
    if (-not (Test-Path $module)) { throw "the toolchain has no $moduleArch runtime at $module" }

    $msidb = Get-ChildItem -Recurse -Filter "MsiDb.exe" `
                 "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if (-not $msidb) { throw "MsiDb.exe was not found in the Windows SDK" }

    $work = Join-Path $Into ".extract"
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    # MsiDb writes beside the database it was given, so work on a copy.
    Copy-Item $module (Join-Path $work "rtl.msm")

    # MsiDb extracts into the process's current directory, which Push-Location alone
    # does not change.
    $wasIn = [Environment]::CurrentDirectory
    Push-Location $work
    [Environment]::CurrentDirectory = $work
    try {
        & $msidb.FullName -d (Join-Path $work "rtl.msm") -x "MergeModule.CABinet" | Out-Null
        if (-not (Test-Path (Join-Path $work "MergeModule.CABinet"))) {
            throw "no cab inside $module"
        }
        # expand refuses a missing destination directory for a multi-file cab.
        New-Item -ItemType Directory -Force -Path (Join-Path $work "files") | Out-Null
        & expand.exe (Join-Path $work "MergeModule.CABinet") -F:* (Join-Path $work "files") | Out-Null
        & $msidb.FullName -d (Join-Path $work "rtl.msm") -f $work -e File | Out-Null
    } finally {
        [Environment]::CurrentDirectory = $wasIn
        Pop-Location
    }

    # File.idt: tab-separated, three header lines, then key ... name, where the name column
    # may hold "8.3|long".
    $table = Join-Path $work "File.idt"
    if (-not (Test-Path $table)) { throw "could not read the file table of $module" }
    $named = 0
    foreach ($line in (Get-Content $table | Select-Object -Skip 3)) {
        $columns = $line -split "`t"
        if ($columns.Count -lt 3) { continue }
        $source = Join-Path "$work\files" $columns[0]
        if (-not (Test-Path $source)) { continue }
        $name = ($columns[2] -split "\|")[-1]
        Move-Item $source (Join-Path $Into $name) -Force
        $named++
    }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    if ($named -eq 0) { throw "nothing came out of $module" }
    Write-Host "  unpacked $named $Architecture runtime libraries from the redistributables"
}

# The MSVC runtime for a target that is not this machine, from Visual Studio's VC\Redist.
function Copy-VisualCRuntime {
    param([string] $Architecture, [string] $Into)

    $vs = Find-VisualStudio
    $redist = Join-Path $vs "VC\Redist\MSVC"
    $version = Get-ChildItem $redist -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match "^[0-9]" } |
               Sort-Object Name -Descending | Select-Object -First 1
    if (-not $version) { return }
    $folder = Get-ChildItem (Join-Path $version.FullName $Architecture) -Directory `
                  -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match "CRT$" } | Select-Object -First 1
    if (-not $folder) { return }
    foreach ($dll in Get-ChildItem $folder.FullName -Filter *.dll) {
        Copy-Item $dll.FullName $Into -Force
    }
}

# ------------------------------------------------------------ does the payload resolve

# What a binary imports, per DLL, and what a DLL exports. Comparing the two is the only
# check that works for an architecture this machine cannot execute -- and the payload for
# the other architecture is precisely the one nobody ever runs before shipping it.
function Get-ImportedSymbols {
    param([string] $Binary)
    $map = @{}
    $current = $null
    foreach ($line in (& dumpbin /nologo /imports $Binary 2>&1)) {
        $text = $line.ToString()
        if ($text -match "^\s{4}(\S+\.dll)\s*$") {
            $current = $matches[1]
            if (-not $map.ContainsKey($current)) {
                $map[$current] = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::Ordinal)
            }
            continue
        }
        # A hint and one token: the entries in between ("Import Address Table" and the
        # like) carry several words and are skipped by the same rule.
        if ($current -and $text -match "^\s+[0-9A-Fa-f]+\s+(\S+)\s*$") {
            [void] $map[$current].Add($matches[1])
        }
    }
    return $map
}

function Get-ExportedSymbols {
    param([string] $Library)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in (& dumpbin /nologo /exports $Library 2>&1)) {
        if ($line.ToString() -match "^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)") {
            [void] $set.Add($matches[1])
        }
    }
    return $set
}

# Every import that a shipped library is supposed to satisfy, checked against what that
# library actually exports. Anything not staged beside the binary is Windows's own and is
# not this script's business.
function Test-StagedPayload {
    param([string] $Architecture, [string] $Staging)

    $imports = Get-ImportedSymbols -Binary (Join-Path $Staging "kmap.exe")
    $missing = @()
    foreach ($library in $imports.Keys) {
        $beside = Join-Path $Staging $library
        if (-not (Test-Path $beside)) { continue }
        $exported = Get-ExportedSymbols -Library $beside
        foreach ($symbol in $imports[$library]) {
            if (-not $exported.Contains($symbol)) { $missing += "$library  $symbol" }
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host "  $($missing.Count) imported symbols are not exported by the staged libraries:"
        $missing | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" }
        throw ("the $Architecture payload would not start - its runtime does not export " +
               "what kmap.exe imports. The runtime beside the binary is the wrong build.")
    }
    Write-Host "  $Architecture verified: every imported symbol resolves against what is shipped"
}

# ---------------------------------------------------------------- what the binary needs

# The DLLs the binary imports, transitively, stopping at the ones Windows itself provides.
function Get-RequiredLibraries {
    param([string] $Binary, [string] $RuntimeDirectory)

    $needed = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Queue]::new()
    $queue.Enqueue($Binary)
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $seen.Add($current)) { continue }
        $output = & dumpbin /nologo /dependents $current 2>&1
        foreach ($line in $output) {
            if ($line -notmatch "^\s+(\S+\.dll)\s*$") { continue }
            $name = $matches[1]
            $candidate = Join-Path $RuntimeDirectory $name
            # Anything not in the runtime folder is Windows's own and already on every machine.
            if (Test-Path $candidate) {
                if ($needed.Add($name)) { $queue.Enqueue($candidate) }
            }
        }
    }
    return $needed
}

# The exe's own icon and version, compiled into a .res the linker takes as an input.
# Without one, Windows gives the console window the default icon and Explorer shows no
# version. Returns the .res path, or $null when there is nothing to compile it with.
function Build-IconResource {
    param([string] $Scratch)

    $icon = Join-Path $root "Assets\app-icon\kmap.ico"
    if (-not (Test-Path $icon)) { return $null }
    $rc = (Get-Command rc.exe -ErrorAction SilentlyContinue).Source
    if (-not $rc) {
        Write-Host "note: no rc.exe on the PATH - kmap.exe will carry no icon"
        return $null
    }
    $version = (Get-Content (Join-Path $root "VERSION") -Raw).Trim()
    # FILEVERSION wants four numbers; VERSION carries three.
    $numbers = @($version -split "\." | ForEach-Object { ($_ -replace "\D", "") }) + @("0", "0", "0", "0")
    $quad = ($numbers[0..3] -join ",")
    # The icon is copied beside the script and named plainly: a path in a resource string
    # would have to have its backslashes escaped. The version constants are numbers, so
    # no SDK header has to be found.
    $text = @"
1 ICON "kmap.ico"
1 VERSIONINFO
FILEVERSION $quad
PRODUCTVERSION $quad
FILEOS 0x4L
FILETYPE 0x1L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904B0"
        BEGIN
            VALUE "CompanyName", "kmap"
            VALUE "FileDescription", "kmap"
            VALUE "FileVersion", "$version"
            VALUE "InternalName", "kmap"
            VALUE "OriginalFilename", "kmap.exe"
            VALUE "ProductName", "kmap"
            VALUE "ProductVersion", "$version"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"@
    New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
    $rcFile = Join-Path $Scratch "kmap.rc"
    $resource = Join-Path $Scratch "kmap.res"
    Copy-Item $icon (Join-Path $Scratch "kmap.ico") -Force
    # UTF-16 is what rc.exe reads without being told, whatever the text holds.
    Set-Content -Path $rcFile -Value $text -Encoding Unicode
    & $rc /nologo /fo $resource $rcFile | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $resource)) {
        Write-Host "note: rc.exe would not compile the icon - kmap.exe will carry none"
        return $null
    }
    return (Resolve-Path $resource).Path
}

# ---------------------------------------------------------------- do it

Import-BuildEnvironment
$runtime = Find-SwiftRuntime
Write-Host "runtime: $runtime"

Push-Location $root
try {
    foreach ($architecture in $Architectures) {
        $staging = Join-Path $payloads $architecture
        # A scratch directory per architecture, and never the plain .build, which belongs
        # to whichever other platform builds this same checkout.
        $scratch = ".build-windows-$architecture"
        $binary = Join-Path $root "$scratch\$Configuration\kmap.exe"

        if (-not $SkipBuild) {
            Write-Host "building $Configuration for $architecture..."
            $arguments = @("build", "-c", $Configuration, "--scratch-path", $scratch)
            if ($architecture -ne $hostArchitecture) {
                $arguments += Get-TargetLinkFlags -Architecture $architecture
            }
            # A .res is architecture-neutral, and link.exe takes it as another input.
            $resource = Build-IconResource -Scratch (Join-Path $root $scratch)
            if ($resource) { $arguments += @("-Xlinker", $resource) }
            & swift @arguments
            if ($LASTEXITCODE -ne 0) { throw "the $architecture build failed" }
        }
        if (-not (Test-Path $binary)) {
            Write-Host "no $architecture binary at $binary - skipping it"
            continue
        }

        # The runtime for the target: the host's is installed; the other is unpacked once.
        $runtimeFor = $runtime
        if ($architecture -ne $hostArchitecture) {
            $runtimeFor = Join-Path $installerOut "runtime\$architecture"
            New-Item -ItemType Directory -Force -Path $runtimeFor | Out-Null
            Export-RuntimeFromMergeModule -Architecture $architecture `
                -SwiftPrograms $script:swiftPrograms -Into $runtimeFor | Out-Null
            Copy-VisualCRuntime -Architecture $architecture -Into $runtimeFor
        }

        if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
        New-Item -ItemType Directory -Force -Path $staging | Out-Null
        Copy-Item $binary $staging

        $libraries = Get-RequiredLibraries -Binary $binary -RuntimeDirectory $runtimeFor
        foreach ($name in $libraries) { Copy-Item (Join-Path $runtimeFor $name) $staging }
        $size = [math]::Round((Get-ChildItem $staging | Measure-Object Length -Sum).Sum / 1MB, 1)
        Write-Host "staged ${architecture}: kmap.exe and $($libraries.Count) libraries - $size MB"
        Test-StagedPayload -Architecture $architecture -Staging $staging
    }
    $staging = Join-Path $payloads $hostArchitecture

    # ------------------------------------------------------------ the installer

    $iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
    if (-not $iscc) {
        foreach ($guess in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                             "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
                             "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
            if (Test-Path $guess) { $iscc = $guess; break }
        }
    }
    if (-not $iscc) {
        Write-Host ""
        Write-Host "Inno Setup is not installed, so no installer was built."
        Write-Host "The folder above runs as it stands - copy it anywhere and start kmap.exe."
        Write-Host "For the installer: winget install JRSoftware.InnoSetup"
        return
    }

    # Ask the staged copy for its version: if it answers, the runtime beside it is right.
    $staged = Join-Path $staging "kmap.exe"
    $version = (& $staged --version) -replace "^kmap\s+", "" -replace "\s.*$", ""
    if (-not $version) { throw "the staged kmap.exe would not run - the runtime beside it is wrong" }

    # Whatever payloads are on disk, not only the ones just built. @() keeps a single
    # match a list.
    $have = @(@("arm64", "x64") | Where-Object { Test-Path (Join-Path $payloads "$_\kmap.exe") })
    $defines = @("/DAppVersion=$version", "/DPayloads=$payloads")
    # IconFile only when the file exists; kmap.iss keys everything about the icon off it.
    $icon = Join-Path $root "Assets\app-icon\kmap.ico"
    if (Test-Path $icon) { $defines += "/DIconFile=$icon" }
    else { Write-Host "note: no Assets\app-icon\kmap.ico - the installer will have no icon" }
    foreach ($architecture in $have) { $defines += "/DHas$architecture=1" }
    # An architecture in the name only when the installer carries that one alone.
    $suffix = if ($have.Count -gt 1) { "" } else { "-$($have[0])" }
    if ($suffix) { $defines += "/DSuffix=$suffix" }
    Write-Host "building the installer for kmap $version, carrying: $($have -join ', ')"
    & $iscc @defines "/O$installerOut" (Join-Path $PSScriptRoot "kmap.iss")
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
    Write-Host "installer: $installerOut\kmap-$version$suffix.exe"
    if ($have.Count -eq 1) {
        Write-Host "  (only $($have[0]) - the other one needs its build tools and Windows"
        Write-Host "   SDK installed; see Scripts/README.md)"
    }
} finally {
    Pop-Location
}
